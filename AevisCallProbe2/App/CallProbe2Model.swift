import AVFoundation
import Foundation
import LiveCommunicationKit
import UIKit

/// ## 通话二探针 —— **主 App 的精简镜像**
///
/// 设计原则：**除了"故意要测的那一项"，其余一切都要和主 App 一致。**
/// 差一样东西，结论就多一个解释不通的口子。
///
/// 详细背景见 `CallProbe2App` 顶上那段。一句话：
/// 第一颗探针只证明了"干净的小包也弹不出来"，但没排除
/// 「主 App 嵌了 `AevisBroadcast.appex`」这条嫌疑。
/// 这颗探针**把主 App 的音轨占用法照搬**过来，同时**故意嵌一个假扩展**，
/// 用来把"嵌扩展"这条原因单独拎出来看。
///
/// ⚠️ 整个类是 `@MainActor`（和两颗探针、主 App 的写法保持一致）；
/// `ConversationManagerDelegate` 那个 extension **不能**加 `@MainActor`，
/// 里面动 `@Published` 一律 `Task { @MainActor in … }`。
@MainActor
final class CallProbe2Model: ObservableObject {

    static let shared = CallProbe2Model()

    private init() {}

    enum Phase: Equatable {
        case idle
        case starting
        case ringing
        case failed

        var title: String {
            switch self {
            case .idle: return "还没测"
            case .starting: return "正在拨…"
            case .ringing: return "✅ 系统界面出来了"
            case .failed: return "❌ 系统没给界面"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    @Published private(set) var justCopied = false

    private var conversationUUID = UUID()
    private var manager: ConversationManager?
    private var autoHangup: Task<Void, Never>?
    private var sawSystemAction = false

    /// 这次是否**先占了音频会话**再拨号（模拟主 App 的 `AudioSession` / QQ 保活）。
    ///
    /// 为什么要有这个开关：主 App 一起床就有一堆东西在动（QQ 长连接的静音保活、
    /// 音乐播放的 `.playback`）。`ConversationManager` 要接管音频会话时，
    /// 如果发现**已经有人在握着**，有可能就不给界面了。
    /// 第一颗探针是干净启动、什么都不抢 —— 这是一个没被排除的变量。
    ///
    /// 开关留在界面上：**同一次安装里两种都试一遍**，比再出一个包快得多。
    @Published var occupyAudioFirst = true

    // MARK: - 体检报告

    func report() async {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        say("=== 二探针体检 ===")
        say("App        : \(short) (\(build))")
        say("Bundle ID  : \(Bundle.main.bundleIdentifier ?? "—")")
        say("系统       : iOS \(UIDevice.current.systemVersion) · \(machineName())")
        say(contentsOf: profileReport())
        say(contentsOf: backgroundReport())
        say(contentsOf: pluginReport())
        say("")

        if #available(iOS 17.4, *) {
            say("系统版本   : ✅ 够（LiveCommunicationKit 要 17.4+）")
        } else {
            say("系统版本   : ❌ 低于 17.4 —— 这就是死因，别的都不用看了")
        }

        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        say("麦克风权限 : " + (mic ? "✅ 给了" : "❌ 没给（下面那次拨号大概率会失败，先给它）"))
        say("")
        say("⚠️ 「先占音频会话」现在是【\(occupyAudioFirst ? "开" : "关")】——")
        say("   两种都试一遍：先按现在的设置拨一次，再切开关拨第二次。")
        say("   两次结果不一样 ⇒ 音频会话被占就是原因之一。")
        say("")
    }

    private func machineName() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// 签名描述文件里到底带了什么。
    ///
    /// ⚠️ 这一段和第一颗探针**完全一样** —— 两颗探针的权限半边必须对齐，
    /// 否则测出来的差异分不清是哪一条造成的。
    private func profileReport() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return [
                "签名描述文件 : 包里没有 embedded.mobileprovision",
                "  · 这一项查不了 —— 但不代表没权限，「下面那次实跑」才算数",
            ]
        }
        let text = String(decoding: data, as: UTF8.self)
        let hasAps = text.contains("aps-environment")
        let hasVoip = text.contains("voip")

        var out = ["签名描述文件 : \(data.count) 字节"]
        out.append("  · 推送权限 aps-environment : " + (hasAps
            ? "✅ 在 —— 通话资格有可能被签进去了（还得看下面实跑）"
            : "❌ 不在 —— 那基本可以判死刑：这套签名没带通话资格"))
        out.append("  · VoIP 推送 background : " + (hasVoip ? "在（走「TA 打给我」那条路要用）" : "不在"))
        out.append("  · 应用组       : " + (text.contains("application-groups") ? "在" : "不在"))
        if let exp = scan("ExpirationDate", in: text) { out.append("  · 过期时间     : \(exp)") }
        if let team = scan("TeamIdentifier", in: text) { out.append("  · 团队         : \(team)") }
        return out
    }

    private func scan(_ key: String, in text: String) -> String? {
        guard let k = text.range(of: "<key>\(key)</key>") else { return nil }
        let rest = text[k.upperBound...]
        guard let s = rest.range(of: "<string>"),
              let e = rest.range(of: "</string>"),
              s.upperBound <= e.lowerBound else { return nil }
        let value = String(rest[s.upperBound..<e.lowerBound])
        return value.count > 58 ? String(value.prefix(58)) + "…" : value
    }

    private func backgroundReport() -> [String] {
        let modes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
        return ["后台模式     : " + (modes.isEmpty ? "❌ 一条都没有" : modes.joined(separator: ", "))]
    }

    /// ⭐ **这一项是这颗探针存在的理由**：包里到底嵌没嵌扩展。
    ///
    /// 主 App 嵌了 `AevisBroadcast.appex` —— 侧载重签时，
    /// **每一个可执行文件都要单独签一份**，扩展那份描述文件必须
    /// 也能覆盖扩展自己的 bundle id。这颗探针故意嵌一个（`PlugIns` 目录下），
    /// 就是为了看"嵌了还弹不弹"。
    ///
    /// 摘掉扩展的做法：在仓库根放 `.release/no-extension` 再推一次
    ///（`scripts/strip_extension.py` 会把带标记的块整段摘掉）。
    private func pluginReport() -> [String] {
        let plugins = Bundle.main.builtInPlugInsURL
        var names: [String] = []
        if let plugins, let items = try? FileManager.default.contentsOfDirectory(
            at: plugins, includingPropertiesForKeys: nil) {
            names = items.map { $0.lastPathComponent }.sorted()
        }
        if names.isEmpty {
            return ["内嵌扩展     : 没有（PlugIns 目录是空的）—— 这次测的是「不嵌扩展」"]
        }
        return ["内嵌扩展     : \(names.joined(separator: ", ")) —— 这次测的是「嵌了扩展」"]
    }

    // MARK: - 真拨一次

    func start() async {
        guard phase != .starting else { return }

        guard #available(iOS 17.4, *) else {
            phase = .failed
            say("❌ 这台机器 iOS \(UIDevice.current.systemVersion) 低于 17.4，LiveCommunicationKit 用不了。")
            return
        }

        phase = .starting
        sawSystemAction = false
        justCopied = false
        say("")
        say("=== 拨号（先占音频会话 = \(occupyAudioFirst ? "开" : "关")）===")

        // ⭐ 模拟主 App 的"一起床就有人在动音频"。
        //    主 App 有 QQ 长连接的静音保活 / 音乐播放，都靠 AVAudioSession 活着。
        //    `ConversationManager` 接管会话时如果发现已经被人握着，有可能就不给界面。
        if occupyAudioFirst {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
                say("✅ 已先占住音频会话（模拟主 App 的后台保活）")
            } catch {
                say("⚠️ 占音频会话失败了（不致命，继续）：\(describe(error))")
            }
        } else {
            say("· 没占音频会话（模拟第一颗探针的干净启动）")
        }

        let config = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: nil,
            maximumConversationGroups: 1,
            maximumConversationsPerConversationGroup: 1,
            includesConversationInRecents: false,
            supportsVideo: false,
            supportedHandleTypes: [.generic]
        )

        let manager = ConversationManager(configuration: config)
        manager.delegate = self
        self.manager = manager
        say("ConversationManager 建好了（这一步没报错）")

        conversationUUID = UUID()
        let handle = Handle(type: .generic, value: "aevis-call", displayName: "Aevis 二探针")

        let action = StartConversationAction(
            conversationUUID: conversationUUID,
            handles: [handle],
            isVideo: false
        )

        say("调 StartConversationAction…（这一步最能说明问题）")
        do {
            try await manager.perform([action])
            say("✅ perform 返回成功，没抛错")
        } catch {
            phase = .failed
            say("❌ 【系统拒绝了】\(describe(error))")
            say("")
            say("这一行就是结论。把这行整份复制给我。")
            releaseAudio(restore: false)
            return
        }

        say("等系统回话（最多 6 秒）…")
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        if sawSystemAction {
            phase = .ringing
            say("")
            say("=====================================")
            say("✅ 【系统把通话界面调出来了】 —— 这条路通！")
            say("=====================================")
        } else if phase == .starting {
            phase = .failed
            say("")
            say("⚠️ perform 没报错，但【系统一直没回调我们】。")
            say("按「没弹出来」算，结论是不通。")
        }

        autoHangup?.cancel()
        autoHangup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.hangUp()
        }
    }

    /// 挂断 + 把音频会话还回去。
    ///
    /// ⚠️ 主 App 里有 `AudioSession.swift` 统一管这件事（"谁借谁还"）。
    /// 探针里没那套东西，就手动还 —— **不还的话下一次测试会被上一次的
    /// 手机状态带偏**（第一次测出来的东西其实是上一次的残留）。
    private func releaseAudio(restore: Bool) {
        guard restore else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    func hangUp() async {
        guard #available(iOS 17.4, *), let manager else { return }
        say("挂断（EndConversationAction）…")
        do {
            try await manager.perform([EndConversationAction(conversationUUID: conversationUUID)])
            say("✅ 挂断成功")
        } catch {
            say("挂断报错（不影响结论）：\(describe(error))")
        }
        manager.delegate = nil
        self.manager = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        say("音频会话已还回去")
    }

    func reset() {
        autoHangup?.cancel()
        autoHangup = nil
        if #available(iOS 17.4, *) {
            manager?.delegate = nil
            manager?.invalidate()
        }
        manager = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        phase = .idle
        sawSystemAction = false
        say("")
        say("=== 已重置（系统里那通话清了、音频会话还了，可以重测）===")
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain) \(ns.code)｜\(ns.localizedDescription)"
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            out += "\n   原因：\(reason)"
        }
        if let suggestion = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
           !suggestion.isEmpty {
            out += "\n   建议：\(suggestion)"
        }
        return out
    }

    // MARK: - delegate 回调

    func noteSystemAction(_ name: String) {
        sawSystemAction = true
        say("⭐ 系统回调：\(name) —— 【这说明界面真的弹出来了】")
    }

    func noteChanged(_ text: String) {
        sawSystemAction = true
        say("⭐ 会话状态：\(text)")
    }

    // MARK: - 日志

    func say(_ line: String) { lines.append(line) }
    func say(contentsOf more: [String]) { lines.append(contentsOf: more) }

    func fullReport() -> String {
        let plugins = Bundle.main.builtInPlugInsURL
        let hasExt = (try? FileManager.default.contentsOfDirectory(
            at: plugins ?? URL(fileURLWithPath: "/dev/null"),
            includingPropertiesForKeys: nil))?.isEmpty == false
        return (["【Aevis 通话二探针】",
                 "结论：\(phase.title)",
                 "收音会话：\(occupyAudioFirst ? "开" : "关")",
                 "嵌扩展：\(hasExt ? "有" : "无")",
                 ""] + lines).joined(separator: "\n")
    }

    func copyAll() {
        UIPasteboard.general.string = fullReport()
        justCopied = true
    }
}

// MARK: - ConversationManagerDelegate
//
// ⚠️ 7 个 required 方法一个都不能少。**不能**给这个 extension 加 `@MainActor`
//    （协议方法不是主 actor 隔离的），所以里面动 `@Published` 一律包 `Task { @MainActor in }`。
extension CallProbe2Model: ConversationManagerDelegate {

    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {
        Task { @MainActor in self.say("· delegate：manager 开始了") }
    }

    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in self.say("· delegate：manager 被重置了") }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        conversationChanged conversation: Conversation
    ) {
        let state = String(describing: conversation.state)
        Task { @MainActor in self.noteChanged("conversationChanged → \(state)") }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in self.noteSystemAction("didActivate（音频会话激活了，通话真的接上了）") }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in self.say("· delegate：音频会话放开了") }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        perform action: ConversationAction
    ) {
        let name = String(describing: type(of: action))

        Task { @MainActor in
            self.noteSystemAction(name)
        }

        if #available(iOS 17.4, *) {
            switch action {
            case let start as StartConversationAction:
                if let conversation = manager.conversations.first(where: { $0.uuid == start.conversationUUID }) {
                    manager.reportConversationEvent(
                        .conversationStartedConnecting(.now),
                        for: conversation
                    )
                    manager.reportConversationEvent(
                        .conversationConnected(.now),
                        for: conversation
                    )
                }
                start.fulfill(dateStarted: .now)

            case let end as EndConversationAction:
                Task { @MainActor in self.say("系统要求挂断 —— 已照做") }
                end.fulfill(dateEnded: .now)

            case let mute as MuteConversationAction:
                Task { @MainActor in self.say("系统要求静音切换 —— 已照做") }
                mute.fulfill()

            default:
                action.fulfill()
            }
        } else {
            action.fulfill()
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        timedOutPerforming action: ConversationAction
    ) {
        let name = String(describing: type(of: action))
        Task { @MainActor in self.say("⚠️ 动作超时了：\(name)（系统没等到我们回话）") }
    }
}
