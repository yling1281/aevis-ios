import AVFoundation
import Foundation
import LiveCommunicationKit
import UIKit

/// ## 通话探针 —— **这不是功能，是一次体检**
///
/// 要回答的只有一句话：
///
/// > **这套签名（侧载重签之后），能不能让 App 弹出系统级的通话界面？**
///
/// ## 背景：为什么非测不可
///
/// Apple 的 `LiveCommunicationKit`（iOS 17.4+，微信"语音通话用弹窗快捷接听"用的那个）
/// 有**两条**路：
///
/// | 路 | 要不要 PushKit 推送 |
/// |---|---|
/// | **收来电** `reportNewIncomingConversation` | ✅ **必须**。文档原话：不报告系统会**杀掉 App** |
/// | **主动拨出** `StartConversationAction` | ❌ **不要**。文档原话："Trigger the system UI using StartConversationAction" |
///
/// 我们这是「你拨给 TA」，走的是**第二条** —— 不需要推送服务器、不需要后端。
///
/// ## ⚠️ 那还测什么？
///
/// 因为还有一道**没人能替你打包票**的关：**签名**。
///
/// `ConversationManager` 要求 App 有通话资格，资格写在 `aps-environment` 这条权限里。
/// 而全能签重签时用的是**它自己的**证书和描述文件 —— 我们写的这条权限
/// 到底有没有被继承过去，**只有真机跑一次才知道**。
///
/// 所以这个探针做两件事，**两条独立的证据**：
///
/// 1. **静态**：扫包里那份 `embedded.mobileprovision`，看里面有没有
///    `aps-environment` —— 直接看签名里到底带了什么。
/// 2. **运行时**：真去调 `ConversationManager.perform([StartConversationAction])`，
///    把系统返回的**原始错误**一字不改打出来。
///
/// 两条都对上，结论才站得住。**只信静态会误判**（描述文件里可能有、
/// 但系统运行时仍然拒绝；也可能是相反的奇怪情况）。
///
/// ⚠️ 这个探针**不接任何媒体的真实通话**：`handleStart` 里只做最小动作
/// （报告 connecting → 报告 connected → fulfill），然后 3 秒后自己挂断。
/// 目的是看**系统界面弹不弹**，不是听声音。
/// 这样用户点一下就能看到结论，也不会真的"打个没人的电话"。
///
/// ⚠️ 整个类是 `@MainActor` 的 —— 今天在音乐那个 bug 上栽过一次：
/// `await` 一个 nonisolated 的 async 函数**会跳回后台线程**，
/// 于是 `@Published` 在后台被改，iOS 26 上直接崩。
@MainActor
final class CallProbeModel: ObservableObject {

    /// ⚠️ 单例 + `private init()` —— **故意**的写法，不是随手抄的。
    /// `@StateObject private var model = CallProbeModel()` 那个默认值表达式
    /// 是在 **App 的 init**（非主 actor 上下文）里求值的，而 `CallProbeModel()`
    /// 是主 actor 隔离的初始化器 —— 在当前 `SWIFT_STRICT_CONCURRENCY=minimal`
    /// 下那是**硬错误**（已经因为同类问题炸过一轮 14 个错）。
    /// 「`static let shared` + 在 App 里读 `shared`」这套是**验证过能编过的**
    /// （VPN 探针 `ProbeModel.shared`、管理端 `AdminStore.shared` 都这么用）。
    static let shared = CallProbeModel()

    private init() {}

    enum Phase: Equatable {
        case idle       // 还没试
        case starting   // 正在拨
        case ringing    // 系统界面出来了 ✅
        case failed     // 系统拒绝了 ❌

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

    /// 探针专用的会话 id。真做功能时一个通话一个 uuid；
    /// 这里只拨一次，固定也行，但用变量方便重复测。
    private var conversationUUID = UUID()

    /// ⚠️ 必须**自己持有** manager（不能只放在局部变量里）。
    /// WWDC 样例里 `manager.delegate = self` 是让 View 持有的；
    /// 真实 App 里 delegate 掉了就什么都不响应了 —— 这是常见翻车点。
    private var manager: ConversationManager?

    /// 3 秒后自己挂断，别留一个"接通了但没人说话"的通话在系统里。
    private var autoHangup: Task<Void, Never>?

    /// 这一轮是不是真的把系统界面调出来了。
    /// `StartConversationAction` 被 fulfill 只说明**我们**做完了，
    /// 真正"界面弹出来了"的证据是 delegate 收到了 start 动作。
    private var sawSystemAction = false

    // MARK: - 体检报告（界面出来之后立刻打一份）

    /// 这几行往往比后面那个报错更有用 —— 报错只说"失败了"，
    /// 这里说的是"为什么"。
    func report() async {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        say("=== 体检 ===")
        say("App        : \(short) (\(build))")
        say("Bundle ID  : \(Bundle.main.bundleIdentifier ?? "—")")
        say("系统       : iOS \(UIDevice.current.systemVersion) · \(machineName())")
        say(contentsOf: profileReport())
        say(contentsOf: backgroundReport())
        say("")
        say("这个探针不接真实通话（3 秒自动挂断），只测「系统界面弹不弹」。")
        say("")

        // 麦克风权限先要下来 —— 不然系统在起会话那一步会拒，
        // 而报错会说"没权限"，很容易被误读成"CallKit 走不通"。
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        say("麦克风权限 : " + (mic ? "✅ 给了" : "❌ 没给（下面那次拨号大概率会失败，先给它）"))
        say("")
    }

    private func machineName() -> String {
        // `UIDevice.current.model` 只会给个 "iPhone"，机型要靠 sysctl
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// ⭐ 最关键的一项：**签名里到底带没带通话资格。**
    ///
    /// 做法很土但很稳：描述文件（`embedded.mobileprovision`）里那段 XML
    /// 是**明文夹在二进制中间**的，直接当字符串扫就行。
    /// 正经解析要过 CMS（Security 那套在 iOS 上不一定编得过），
    /// 这里是"只回答一个问题"，不值得冒编译不过的风险。
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

    /// 在明文里找 `<key>名字</key>` 后面第一对 `<string>…</string>`。
    private func scan(_ key: String, in text: String) -> String? {
        guard let k = text.range(of: "<key>\(key)</key>") else { return nil }
        let rest = text[k.upperBound...]
        guard let s = rest.range(of: "<string>"),
              let e = rest.range(of: "</string>"),
              s.upperBound <= e.lowerBound else { return nil }
        let value = String(rest[s.upperBound..<e.lowerBound])
        return value.count > 58 ? String(value.prefix(58)) + "…" : value
    }

    /// 两条后台模式到底进包没有。
    /// ⚠️ 这条能排掉一类误判：**后台模式没进包** 和 **权限不对**，
    /// 在界面上表现出来的失败几乎一样。
    private func backgroundReport() -> [String] {
        let modes = (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
        return ["后台模式     : " + (modes.isEmpty ? "❌ 一条都没有" : modes.joined(separator: ", "))]
    }

    // MARK: - 真拨一次

    /// 拨一通"假的"电话 —— 只为了看系统界面弹不弹。
    func start() async {
        guard phase != .starting else { return }
        phase = .starting
        sawSystemAction = false
        justCopied = false
        say("")
        say("=== 拨号 ===")

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
        let handle = Handle(type: .generic, value: "aevis-probe", displayName: "Aevis 探针")

        var action = StartConversationAction(
            conversationUUID: conversationUUID,
            handles: [handle],
            isVideo: false
        )
        // ⚠️ 只留「静音」一个能力，别声明 video/merging —— 声明了系统会按那个
        //    去要更多东西，探针没必要给自己加变量。
        action.capabilities = [.pausing]

        say("调 StartConversationAction…（这一步最能说明问题）")
        do {
            try await manager.perform([action])
            say("✅ perform 返回成功，没抛错")
        } catch {
            phase = .failed
            say("❌ 【系统拒绝了】\(describe(error))")
            say("")
            say("这一行就是结论。把这行整份复制给我。")
            return
        }

        // perform 成功只说明"我们请求了"。真正弹没弹，得看 delegate 有没有被回调。
        say("等系统回话（最多 6 秒）…")
        try? await Task.sleep(nanoseconds: 6_000_000_000)

        if sawSystemAction {
            phase = .ringing
            say("")
            say("=====================================")
            say("✅ 【系统把通话界面调出来了】 —— 这条路通！")
            say("=====================================")
            say("也就是说：不用推送服务器、不用上架，")
            say("侧载包也能有系统级通话界面。")
            say("（界面这会儿应该已经自己挂断了）")
        } else if phase == .starting {
            phase = .failed
            say("")
            say("⚠️ perform 没报错，但【系统一直没回调我们】。")
            say("这通常意味着界面其实没弹出来 ——")
            say("权限看着有、但实际没生效 —— 这是侧载常见的半吊子状态。")
            say("按「没弹出来」算，结论是不通。")
        }

        autoHangup?.cancel()
        autoHangup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.hangUp()
        }
    }

    /// 收尾：把这次会话从系统里摘干净。
    /// ⚠️ 不做这一步的话，系统里可能留一条"进行中"的通话，
    /// 下一次测试的状态会被它带偏（第二次测出来的是上一次的残留）。
    func hangUp() async {
        guard let manager else { return }
        say("挂断（endConversation）…")
        do {
            try await manager.endConversation(uuid: conversationUUID)
            say("✅ 挂断成功")
        } catch {
            say("挂断报错（不影响结论）：\(describe(error))")
        }
        manager.delegate = nil
        self.manager = nil
    }

    /// 把系统里可能残留的通话全清掉 —— 重测前先点一下这个。
    func reset() {
        autoHangup?.cancel()
        autoHangup = nil
        manager?.delegate = nil
        manager = nil
        phase = .idle
        sawSystemAction = false
        say("")
        say("=== 已重置（本地状态清干净了，可以重测）===")
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

    // MARK: - delegate 回调进来的地方（由 extension 调）

    func noteSystemAction(_ name: String) {
        sawSystemAction = true
        say("⭐ 系统回调：\(name) —— 【这说明界面真的弹出来了】")
    }

    // MARK: - 日志与复制

    func say(_ line: String) { lines.append(line) }
    func say(contentsOf more: [String]) { lines.append(contentsOf: more) }

    /// 整份报告 —— 复制给我看的就是这个。
    func fullReport() -> String {
        (["【Aevis 通话探针】", "结论：\(phase.title)", ""] + lines).joined(separator: "\n")
    }

    func copyAll() {
        UIPasteboard.general.string = fullReport()
        justCopied = true
    }
}

// MARK: - ConversationManagerDelegate

/// ⚠️ **这个 extension 不能用 `@MainActor` 包**（协议方法不是主 actor 隔离的），
/// 所以里面动 `@Published` 一律 `Task { @MainActor in … }` —— 这条今天刚踩过
/// （音乐闪退就是"后台改 @Published"）。
extension CallProbeModel: ConversationManagerDelegate {

    /// 系统把"用户/system 发起的动作"派回来。
    /// 我们主动拨出时，**系统界面弹出来那一下就会回调这里**（`.start`）。
    /// 所以「收到这个回调」= 「界面真的弹了」。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        perform action: ConversationAction
    ) {
        let name = String(describing: type(of: action))

        Task { @MainActor in
            self.noteSystemAction(name)
        }

        // ⚠️ 必须 fulfill（或 fail），否则系统会一直等我们，
        //    那个"通话"卡在半空中，用户会看到一个转不出去的界面。
        switch action {
        case let start as StartConversationAction:
            // 真实通话是在这里接上媒体流；探针只要"接通"这个状态。
            Task { @MainActor in
                let uuid = self.conversationUUID
                manager.reportConversationEvent(.conversationStartedConnecting(.now),
                                                for: self.manager?.conversations
                                                    .first { $0.uuid == uuid } ?? start.conversationUUID)
            }
            start.fulfill()

        case let end as EndConversationAction:
            Task { @MainActor in self.say("系统要求挂断 —— 已照做") }
            end.fulfill()

        case let mute as MuteConversationAction:
            Task { @MainActor in self.say("系统要求静音切换 —— 已照做") }
            mute.fulfill()

        default:
            action.fulfill()
        }
    }
}
