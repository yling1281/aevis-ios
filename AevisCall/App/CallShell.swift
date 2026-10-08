import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(LiveCommunicationKit)
import LiveCommunicationKit
#endif

/// 「Aevis 通话」这个独立小包的全部通话逻辑 —— 只做一件事：把苹果的系统通话界面弹出来。
///
/// ## 这一轮的范围（老板 2026-10-01 定的生死线）
/// 起来 → 弹系统通话界面（灵动岛 / 锁屏）→ 挂断，外加可自定义的头像与显示名。
/// 不接声音、不接通讯录、不接 LLM —— 那些是后续步骤。
/// 理由写在设计稿第 8 节：空壳都弹不出来，后面全白做。
///
/// ## 形状照抄谁
/// `AevisCallProbe/App/CallProbeModel.swift` —— 那颗探针在老板真机上跑通了
/// （灵动岛上真的弹出了系统通话界面）。所以这里的每一处调用都逐行照抄它：
/// 参数名、参数标签、候选值都不改。不要凭记忆自创 API ——
/// 本机没有 Xcode、iOS 只能靠 GitHub Actions 编，一轮约 25 分钟，写错一次就是半小时。
///
/// ## 两条路，我们只走一条
/// 收来电（reportNewIncomingConversation）必须带推送，文档原话「不报系统会杀掉 App」；
/// 主动拨出（StartConversationAction）不需要推送。
/// 我们走第二条：不需要推送服务器、不需要上架，所以侧载包也能弹。
///
/// ## 会话是异步登记的（探针那轮踩过）
/// `perform(_:)` 返回之后，会话不一定马上出现在 `manager.conversations` 里。
/// 那一刻去查往往查不到，于是系统那张卡的计时器会一直停在 0:00。
/// Apple 官方示例是 perform 之后 sleep 一秒再回头找；这里照抄主 App 里
/// 已经验证过的 `reportConnected(attemptsLeft:)`（每 0.3 秒重试、最多 15 次）。
///
/// ## 为什么整个类标 `@MainActor`
/// 主 App 在音乐那个 bug 上栽过：`await` 一个 nonisolated 的 async 函数会跳回后台线程，
/// 于是 `@Published` 在后台被改，iOS 26 上直接崩。这类全标 `@MainActor` 最省事。
@MainActor
final class CallShell: ObservableObject {

    /// ⚠️ 单例 + `private init()` —— 故意这么写，不是随手抄的。
    /// App 里 `@StateObject private var shell = CallShell.shared` 那个默认值表达式
    /// 是在非主 actor 上下文里求值的；直接 `CallShell()`（主 actor 隔离的初始化器）
    /// 在那个上下文里是硬错误。读 `shared` 这套是验证过能编过的。
    static let shared = CallShell()

    private init() {}

    // MARK: - 状态

    enum Phase: Equatable {
        case idle       // 还没试
        case starting   // 正在拨
        case ringing    // 系统界面出来了
        case failed     // 系统拒绝了
        case ended      // 已挂断

        var title: String {
            switch self {
            case .idle: return "还没试"
            case .starting: return "正在拨…"
            case .ringing: return "系统界面出来了"
            case .failed: return "系统没给界面"
            case .ended: return "已挂断"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    @Published private(set) var justCopied = false

    /// 上一次「让系统弹通话界面」为什么没成 —— 只在真失败之后才有值（成功就是 nil）。
    ///
    /// ⚠️ 为什么摆到台面上：以前这类失败只写进日志，用户点了按钮看到的就是
    ///    「什么都没发生」，只能猜。现在失败原因挂出来，界面上直接显示一行。
    @Published private(set) var lastFailure: String?

    /// 这一通是否已经报过「接通」。补报是一条会重试的链，没有幂等闸就会重复上报。
    private var connectedReportedFor: UUID?

    /// 系统是否回调过我们 —— 这是「界面真的弹了」的硬证据
    /// （perform 没报错只说明我们请求了，不代表系统给了界面）。
    private var sawSystemAction = false

    /// 自动挂断的定时任务（这一版只让老板看一眼界面，不真打电话）。
    private var autoHangup: Task<Void, Never>?

    /// 一通电话一个 uuid。
    private var conversationUUID = UUID()

    #if canImport(LiveCommunicationKit)
    /// ⚠️ 必须自己持有 manager。只放在局部变量里的话，delegate 地址一掉就什么都不响应。
    private var manager: ConversationManager?
    #endif

    // MARK: - 这台机器能不能用

    /// 有没有可能用系统通话界面。
    ///
    /// ⚠️ 这是「能不能调」，不是「调了会不会成」。签名那一关只有真机知道 ——
    ///    这个值不能拿来当「一定成功」的承诺，只用来提前省掉无谓的调用。
    static var isSupported: Bool {
        #if canImport(LiveCommunicationKit)
        return true
        #else
        return false
        #endif
    }

    /// 不支持时，如实说为什么。
    ///
    /// ⚠️ 目标 deploymentTarget 就是 17.4，这个包也只在 17.4+ 装得上 ——
    ///    所以「能用」时这里恒为空串（永远不会显示）。
    ///    真正会走到这里的只有一种情况：**编译这个包的 SDK 里根本没有
    ///    LiveCommunicationKit**（也就是 `#else` 那条路）。所以那句话必须如实，
    ///    不能含糊成「出错了」。这跟跑通的一探针是同一个形状：不写 availability 守卫。
    static var unsupportedReason: String {
        #if canImport(LiveCommunicationKit)
        return ""
        #else
        return "这个 SDK 里没有 LiveCommunicationKit，弹不出苹果的通话界面。"
        #endif
    }

    // MARK: - 拨出

    /// 拨出去 —— 让系统把通话界面（灵动岛 / 锁屏）调出来。
    ///
    /// - Parameters:
    ///   - displayName: 系统界面上显示的「对方名字」。
    ///   - iconTemplateData: 交给系统那张卡的图标数据（模板图，见 CallIdentityStore）。
    func start(displayName: String, iconTemplateData: Data?) {
        guard phase != .starting else { return }
        lines.removeAll()
        justCopied = false
        lastFailure = nil

        guard CallShell.isSupported else {
            let why = CallShell.unsupportedReason
            phase = .failed
            lastFailure = why
            say("❌ " + why)
            return
        }

        #if canImport(LiveCommunicationKit)
        beginConversation(displayName: displayName, iconTemplateData: iconTemplateData)
        #endif
    }

    /// 收掉系统那边这一通。幂等，没开过的时候调它什么都不做。
    func hangUp() {
        #if canImport(LiveCommunicationKit)
        endConversation()
        #endif
    }

    /// 把系统里可能残留的通话清干净 —— 重试前用。
    ///
    /// ⚠️ 不做这一步的话，系统里可能留一条「进行中」的通话，
    ///    下一次测试的状态会被它带偏（第二次测出来的是上一次的残留）。
    func reset() {
        autoHangup?.cancel()
        autoHangup = nil
        #if canImport(LiveCommunicationKit)
        manager?.delegate = nil
        // invalidate() 会顺手把还挂着的会话全结束掉，比只置 nil 干净。
        manager?.invalidate()
        manager = nil
        #endif
        connectedReportedFor = nil
        sawSystemAction = false
        phase = .idle
        say("")
        say("=== 已重置（本地状态清干净了，可以重试）===")
    }

    // MARK: - 给 delegate 回调进来的入口（由文件末尾的 extension 调）

    /// 系统把动作 / 状态回调回来了 —— 收到它 = 界面真的弹出来了。
    func noteSystemAction(_ name: String) {
        sawSystemAction = true
        say("⭐ 系统回调：\(name) —— 【这说明界面真的弹出来了】")
    }

    func noteChanged(_ text: String) {
        sawSystemAction = true
        say("⭐ " + text)
    }

    // MARK: - 日志与复制

    func say(_ line: String) { lines.append(line) }

    /// 整份报告 —— 复制出来给老板看的就是这个。
    func fullReport() -> String {
        (["【Aevis 通话】", "结论：\(phase.title)", ""] + lines).joined(separator: "\n")
    }

    func copyAll() {
        #if canImport(UIKit)
        UIPasteboard.general.string = fullReport()
        #endif
        justCopied = true
    }

    // MARK: - 错误翻译

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain) \(ns.code)｜\(ns.localizedDescription)"
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            out += "｜原因：\(reason)"
        }
        if let suggestion = ns.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String,
           !suggestion.isEmpty {
            out += "｜建议：\(suggestion)"
        }
        return out
    }

    /// 把那一串 NSError 翻成用户看得懂的一句话。
    ///
    /// ⚠️ 别把 code 写死成判断依据 —— 只用来挑一句更贴切的话，
    ///    认不出来就退回通用那句，照样把原始信息带上。
    private static func friendlyFailure(_ error: Error) -> String {
        let ns = error as NSError
        // CallKit error 族里 code 4 一般是资格 / 权限不足（探针真机上就是这个 4）。
        if ns.domain.contains("CallKit") {
            return "苹果那套来电界面调不出来（这台签名没给通话资格，code \(ns.code)）。"
        }
        return "苹果那套来电界面调不出来。"
    }

    // MARK: - 真正跟 ConversationManager 打交道的那一段

    #if canImport(LiveCommunicationKit)

    /// 传给系统的「对方号码」。系统界面里显示的是 Handle.displayName，
    /// 这个 value 只是我们这边的标识，不显示给用户。
    private static let handleValue = "aevis-call"

    /// 拨出去。LiveCommunicationKit 全线 iOS 17.4+。
    private func beginConversation(displayName: String, iconTemplateData: Data?) {
        phase = .starting
        sawSystemAction = false
        connectedReportedFor = nil

        // 上一通还挂着就先清干净 —— 系统里留一条进行中的通话会把这一通的状态带偏。
        if manager != nil { endConversation() }

        say("")
        say("=== 拨号 ===")

        // ⚠️ 这份 Configuration 逐字照抄探针（CallProbeModel.start()）。
        //    除了 iconTemplateImageData 换成老板自定义的头像模板图，
        //    其余每个参数名、每个取值都不动 —— 那是真机验过能弹的形状。
        let config = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: iconTemplateData,
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
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = Handle(
            type: .generic,
            value: CallShell.handleValue,
            displayName: name.isEmpty ? "ta" : name
        )
        let action = StartConversationAction(
            conversationUUID: conversationUUID,
            handles: [handle],
            isVideo: false
        )

        observeOutcome()

        say("调 StartConversationAction…（这一步最能说明问题）")
        Task {
            do {
                try await manager.perform([action])
                say("✅ perform 返回成功，没抛错 —— 等系统回话（最多 6 秒）")
                // 3~5 秒后自动挂断：老板要的是「看它弹没弹」，不是真打一通电话。
                scheduleAutoHangup()
            } catch {
                lastFailure = CallShell.friendlyFailure(error)
                phase = .failed
                say("❌ 【系统拒绝了】" + CallShell.describe(error))
                say("这一行就是结论。")
                teardownSystem()
            }
        }
    }

    /// 等系统回话：收到 delegate 回调就算「界面弹出来了」。
    private func observeOutcome() {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.sawSystemAction {
                self.phase = .ringing
                self.say("")
                self.say("=====================================")
                self.say("✅ 【系统把通话界面调出来了】 —— 这条路通！")
                self.say("=====================================")
            } else if self.phase == .starting {
                self.phase = .failed
                self.lastFailure = "系统没给界面：perform 没报错、系统也一直没回调 —— 这台签名多半没拿到通话资格。"
                self.say("")
                self.say("⚠️ perform 没报错，但系统一直没回调 —— 按「没弹出来」算。")
            }
        }
    }

    /// 3~5 秒后自动挂断 —— 别在系统里留一条「接通了但没人说话」的通话。
    private func scheduleAutoHangup() {
        autoHangup?.cancel()
        autoHangup = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.endConversation()
        }
    }

    /// 收掉这一通。幂等：manager 已经清掉时直接收住，不会转圈。
    private func endConversation() {
        autoHangup?.cancel()
        autoHangup = nil
        guard let manager else { return }
        self.manager = nil
        manager.delegate = nil
        let uuid = conversationUUID
        connectedReportedFor = nil
        say("挂断（EndConversationAction）…")
        Task {
            // ⚠️ 没有 endConversation(uuid:) 这个方法；正解是再走一次 perform，
            //    把 EndConversationAction 派给系统。
            try? await manager.perform([EndConversationAction(conversationUUID: uuid)])
            manager.invalidate()
        }
        if phase == .starting { phase = .ended }
    }

    /// 出错了把系统那边摘干净，别留一条半死不活的会话。
    private func teardownSystem() {
        autoHangup?.cancel()
        autoHangup = nil
        manager?.delegate = nil
        manager?.invalidate()
        manager = nil
        connectedReportedFor = nil
    }

    // MARK: - 把「已接通」补报给系统
    //
    // 系统那张卡的计时器 = 现在 减去 我们报上去的接通时刻。
    // `reportConversationEvent` 要的是 `Conversation` 对象（不是 uuid），
    // 而会话是异步登记的 —— 所以这里要一直重试到找到它为止，否则计时器停在 0:00。
    private func reportConnected(attemptsLeft: Int = 15) {
        guard let manager else { return }
        guard connectedReportedFor != conversationUUID else { return }

        if let conversation = manager.conversations.first(where: { $0.uuid == conversationUUID }) {
            manager.reportConversationEvent(.conversationConnected(.now), for: conversation)
            connectedReportedFor = conversationUUID
            say("✅ 已报「接通」（第 \(16 - attemptsLeft) 次尝试）")
            return
        }

        guard attemptsLeft > 0 else {
            // 等到这里说明会话一直没进列表 —— 系统卡的计时器不会走。
            say("⚠️ 一直没等到会话，系统卡的计时器不会走")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.reportConnected(attemptsLeft: attemptsLeft - 1)
        }
    }

    #endif
}

// MARK: - ConversationManagerDelegate
//
// ⚠️⚠️ 这个协议一共 7 个 required 方法，少一个就编译不过，
// 而且编译器的报错会指到「argument labels 不一样」上，很容易看歪。
// 必须全的：DidBegin / DidReset / conversationChanged / didActivate /
// didDeactivate / perform / timedOutPerforming。
//
// ⚠️ 这个 extension 不能用 `@MainActor` 包（协议方法不是主 actor 隔离的），
// 所以里面动 `@Published` 一律 `Task { @MainActor in … }`。
#if canImport(LiveCommunicationKit)
extension CallShell: ConversationManagerDelegate {

    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {
        Task { @MainActor in self.say("· delegate：manager 开始了") }
    }

    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in self.say("· delegate：manager 被系统重置了") }
    }

    /// 会话状态变了 —— 这条是「系统真的在建这个通话」的硬证据。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        conversationChanged conversation: Conversation
    ) {
        let state = String(describing: conversation.state)
        let uuid = conversation.uuid
        Task { @MainActor in
            self.noteChanged("会话状态 → \(state)")
            // 兜底：会话一旦出现在列表里就补报「接通」（同主 App 写法）。
            guard uuid == self.conversationUUID,
                  self.connectedReportedFor != uuid,
                  let mgr = self.manager,
                  let hit = mgr.conversations.first(where: { $0.uuid == uuid }) else { return }
            mgr.reportConversationEvent(.conversationConnected(.now), for: hit)
            self.connectedReportedFor = uuid
            self.say("✅ 会话出现时补报了「接通」")
        }
    }

    /// 系统把音频会话交给 App 了 —— 说明通话真的接通了（界面已弹出）。
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

    /// 系统把「用户 / 系统发起的动作」派回来。
    /// 我们主动拨出时，系统界面弹出来那一下就会回调这里。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        perform action: ConversationAction
    ) {
        let name = String(describing: type(of: action))
        Task { @MainActor in self.noteSystemAction(name) }

        // ⚠️ 必须 fulfill（或 fail），否则系统会一直等我们，
        //    那个「通话」卡在半空中，用户会看到一个转不出去的界面。
        switch action {
        case let start as StartConversationAction:
            // 真实通话的媒体流是在这里接上的；这一版只要「接通」这个状态。
            // ⚠️ reportConversationEvent 要的是 Conversation 对象（不是 uuid）。
            if let conversation = manager.conversations.first(where: { $0.uuid == start.conversationUUID }) {
                manager.reportConversationEvent(.conversationStartedConnecting(.now), for: conversation)
            }
            start.fulfill(dateStarted: .now)
            // 「已接通」交给 reportConnected —— 那条会一直重试到找到会话为止。
            Task { @MainActor in self.reportConnected() }

        case let end as EndConversationAction:
            end.fulfill(dateEnded: .now)
            Task { @MainActor in self.endConversation() }

        case let mute as MuteConversationAction:
            mute.fulfill()

        default:
            action.fulfill()
        }
    }

    /// 系统等我们 fulfill 等到超时了 —— 这是「卡住」的信号，要留下来。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        timedOutPerforming action: ConversationAction
    ) {
        let name = String(describing: type(of: action))
        Task { @MainActor in self.say("⚠️ 动作超时了：\(name)（系统没等到我们回话）") }
    }
}
#endif
