import AVFoundation
import Foundation

#if canImport(LiveCommunicationKit)
import LiveCommunicationKit
#endif

/// 系统级通话界面（苹果那套）。
///
/// ## 用户要的（2026-10-01）
/// 「苹果系统来电界面」—— 就是微信那个「语音通话用弹窗快捷接听」的样子：
/// 灵动岛 / 锁屏上是**系统的**通话卡片，能接、能挂，不像个"App 里的一个页面"。
/// 底层是 `LiveCommunicationKit`（iOS 17.4+）。
///
/// ## 为什么先出了一个探针
/// 只有一件事没人能替你打包票：**签名**。`ConversationManager` 要求 App 有通话资格，
/// 资格写在 `aps-environment` 这条权限里，而全能签重签用的是**它自己的**证书和
/// 描述文件 —— 我们写的那条到底有没有被继承过去，只有真机跑一次才知道。
/// 所以先出了 `AevisCallProbe`（`https://sucai.aevis.cn/CallProbe-3086.ipa`），
/// 这里是把探针里**验证过能编过的那套用法原样搬过来**。
///
/// ## 两条路，我们只走一条
/// | 路 | 要不要 PushKit 推送 |
/// |---|---|
/// | **收来电** `reportNewIncomingConversation` | ✅ **必须**（文档原话：不报告系统会**杀掉 App**） |
/// | **主动拨出** `StartConversationAction` | ❌ **不要** |
///
/// 我们走的是"**你拨给 ta**"这条 —— 不需要推送服务器、不需要后端、不需要上架。
/// 「ta打给你」那条走的是**本地通知**（见 `ProactiveService`），不是这条路：
/// 侧载包没有 APNs 付费账号，`reportNewIncomingConversation` 根本喂不到我们手上。
///
/// ## ⚠️ 这里是**包装层**，不是功能本身
/// 外面（`CallService` / `AppRouter`）看不见 `LiveCommunicationKit` 的任何类型，
/// 所以主 App 里只要**这一个文件**去操心 iOS 17.4 和框架在不在。
/// 调用点只管说"开始 / 挂断"，剩下的（版本不够、系统拒绝、签名没资格）全在这里吞掉。
///
/// ⚠️ 主 App 的 deploymentTarget 是 **17.0**，比 LiveCommunicationKit 低。
///    所以每一处用法都**必须**在 `#if canImport(...)` 和 `if #available(iOS 17.4, *)`
///    里面 —— 少一层就是编译错误。
enum SystemCall {

    /// 这台机器**有没有可能**用系统通话界面。
    ///
    /// ⚠️ 这是"能不能调"，不是"调了会不会成"。签名那一关只有真机知道 ——
    ///    所以这个值**不能**拿来当"一定成功"的承诺，只用来提前省掉无谓的调用。
    static var isSupported: Bool {
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) { return true }
        #endif
        return false
    }

    /// 拨出去（让系统把通话界面调出来）。
    ///
    /// **不做任何返回**，也不抛错：失败是预期内的结果之一 ——
    /// 那时候我们自己的通话界面还在跑，用户完全无感，只是没看到灵动岛上那张卡。
    /// 失败会记进黑匣子，方便回头对账。
    static func start(displayName: String) {
        guard isSupported else { return }
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) {
            Task { @MainActor in
                SystemCallCenter.shared.start(displayName: displayName)
            }
        }
        #endif
    }

    /// 收掉系统那边这一通。幂等，没开过的时候调它什么都不做。
    static func hangUp() {
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) {
            Task { @MainActor in
                SystemCallCenter.shared.hangUp()
            }
        }
        #endif
    }

    /// 把 App 这边的静音状态推给系统那张通话卡（让它上面的按钮跟着亮/灭）。
    ///
    /// 用户 2026-10-02 报的「打电话点击静音和挂断，就是 APP 同步不了」——
    /// 反方向（系统 → App）由 `MuteConversationAction` 负责，这个是正方向。
    static func pushMuted(_ value: Bool) {
        guard isSupported else { return }
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) {
            Task { @MainActor in
                SystemCallCenter.shared.pushMuted(value)
            }
        }
        #endif
    }

    /// 上一次「让系统弹电话界面」为什么没成（成功就是空）。
    ///
    /// 给通话页显示用 —— 用户报「电话弹窗弹不了」，就得让他**看得见**原因，
    /// 而不是去黑匣子里翻。
    ///
    /// ⚠️ `SystemCallCenter` 是 `@MainActor` 的，`lastFailure` 也挂在它身上 ——
    ///    所以这个转发**必须 `@MainActor`**。去掉它 CI 就会报
    ///    「main actor-isolated property 'lastFailure' can not be referenced
    ///      from a nonisolated context」（真挂过）。
    ///    调用处（`CallView.statusBlock`）本来就在主线程上求值，所以不影响谁。
    @MainActor
    static var lastFailure: String? {
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) { return SystemCallCenter.shared.lastFailure }
        #endif
        return nil
    }

    /// ⭐ **「失败刚刚发生」的信号灯**，给 SwiftUI 的 `onChange` 用。
    ///
    /// 为什么不能直接 `onChange(of: SystemCall.lastFailure)`：
    /// `lastFailure` 是**计算属性**，它自己不持有状态，`onChange` 观察一个
    /// 每次求值都可能变化的计算属性，行为不确定（而且这里还包着
    /// `#available` / `#if canImport`，编译器看它永远是同一个表达式）。
    ///
    /// 所以改成一个**只增不减的计数器**：每失败一次 +1。`onChange` 看到值变了
    /// 就知道"刚刚又失败了一次"，再去读 `lastFailure` 拿具体原因。
    ///
    /// ⚠️ 为什么不用 `@Published` / `ObservableObject`：这个类型是 `enum`（静态
    /// 命名空间），塞不进 SwiftUI 的观察体系。`enum` + `static var` 在这里最省事，
    /// 而且调用点只有一个（`ChatView`），不存在谁忘了订阅的问题。
    ///
    /// ⚠️ 只 `@MainActor`：写它的地方（`SystemCallCenter.start` 的 catch）
    /// 已经在主 actor 上，读它的是 SwiftUI body（也在主线程）。
    @MainActor
    static var callFailureTick: Int {
        #if canImport(LiveCommunicationKit)
        if #available(iOS 17.4, *) { return SystemCallCenter.shared.failureTick }
        #endif
        return 0
    }
}

#if canImport(LiveCommunicationKit)

/// 真正跟 `ConversationManager` 打交道的那一层。
///
/// ⚠️ `@MainActor` + `static let shared` + `private init()` —— 这套写法是**故意**的：
///    跟 `CallProbeModel` 完全一致（那套已经在 CI 上编过、出过包）。
///    别改成 `@StateObject private var … = SystemCallCenter()`，
///    那个默认值表达式在非主 actor 上下文里求值，是硬错误。
@available(iOS 17.4, *)
@MainActor
final class SystemCallCenter {

    static let shared = SystemCallCenter()

    private init() {}

    /// ⚠️ **必须自己持有** manager。
    /// 只放在局部变量里的话，delegate 地址一掉就什么都不响应了 ——
    /// 这是这套 API 最常见的翻车点。
    private var manager: ConversationManager?

    /// 一通电话一个 uuid。挂断换一个新的，免得跟上一次的残留串起来。
    private var conversationUUID = UUID()

    /// 传给系统的"对方号码"。系统界面里显示的是 `Handle.displayName`，
    /// 这个 value 只是我们这边的标识。
    private static let handleValue = "aevis-call"

    /// 系统界面里显示的"对方名字"（人设名），拨号时记下来给 `Handle` 用。
    private var displayName = "ta"

    /// 上一次调出系统界面**失败**的原因（成功就是 nil）。
    ///
    /// ⚠️ 为什么要把它摆到台面上：用户 2026-10-01 报「电话弹窗不知道为什么弹不了」。
    ///    以前这里失败只写黑匣子，界面上**一点动静都没有** —— 用户看到的就是
    ///    "点了打电话，然后什么都没有"，只能猜。现在失败原因挂出来，
    ///    在通话页上显示一行小字，一眼就知道是签名没资格、还是系统版本不够。
    private(set) var lastFailure: String?

    /// 失败了几次。**只增不减** —— 给 SwiftUI 当"刚刚又失败了"的信号灯用。
    /// 见 `SystemCall.callFailureTick` 那段注释（为什么不能用 `lastFailure` 观察）。
    private(set) var failureTick = 0

    /// 「已接通」这件事**已经报给系统了**的那一通。
    ///
    /// ⚠️ 必须有它：补报是一条会重试的链（见 `reportConnected`），
    ///    没有这个标记就会重复上报 —— 计时器被反复重置，比不报还难看。
    private var connectedReportedFor: UUID?

    // MARK: - 拨出

    func start(displayName: String) {
        self.displayName = displayName.isEmpty ? "ta" : displayName
        lastFailure = nil
        BlackBox.log("📞 系统通话界面：请求调出（\(self.displayName)）")

        // 上一通还在就先清干净。系统里留着一条"进行中"的通话，
        // 会把这一通的状态带偏（探针那轮踩过：第二次测出来的是上一次的残留）。
        if manager != nil { hangUp() }

        let config = ConversationManager.Configuration(
            ringtoneName: nil,
            iconTemplateImageData: nil,
            maximumConversationGroups: 1,
            maximumConversationsPerConversationGroup: 1,
            // ⚠️ 先 `false` —— 这是探针里**跑通过**的那份配置，一个字都不改。
            //    想让通话进系统电话 App 的"最近通话"，把这里改成 true 试试就行，
            //    但那是另一件事，等这一版真机验过再说。
            includesConversationInRecents: false,
            supportsVideo: false,
            supportedHandleTypes: [.generic]
        )

        let manager = ConversationManager(configuration: config)
        manager.delegate = self
        self.manager = manager

        conversationUUID = UUID()
        connectedReportedFor = nil
        let handle = Handle(
            type: .generic,
            value: Self.handleValue,
            displayName: self.displayName
        )
        let action = StartConversationAction(
            conversationUUID: conversationUUID,
            handles: [handle],
            isVideo: false
        )

        Task {
            do {
                try await manager.perform([action])
                lastFailure = nil
                BlackBox.log("📞 系统通话界面：请求已发出（等系统回话）")
            } catch {
                // ⚠️ 这里**不打断通话** —— 我们自己的通话界面还在跑。
                //
                // 系统不给界面（这套侧载签名没继承通话资格 / 描述文件里没有
                // `aps-environment`）是**预期内**的结果之一，为了"灵动岛上没出那张卡"
                // 去中断一通正在进行的电话，那是本末倒置。
                //
                // 但**必须记下来并让用户看得到**：以前只在黑匣子里留一行，
                // 用户点了打电话什么都没有，只能猜"是不是坏了"。
                let detail = Self.describe(error)
                lastFailure = Self.friendlyFailure(error)
                failureTick += 1
                BlackBox.failure("📞 系统通话界面不可用（退回自己的界面）", detail: detail)
                self.teardown()
            }
        }
    }

    /// 把那一串 `NSError` 翻成用户看得懂的一句话。
    ///
    /// 通话页上那行小字就是它 —— 所以别写成 `CallKit error 4`，
    /// 要写成"这台签名没给通话资格，所以苹果那套界面调不出来"。
    private static func friendlyFailure(_ error: Error) -> String {
        let ns = error as NSError
        // `com.apple.CallKit.error.requesttransaction` 那一族的 code：
        // 1 = 未授权，4 = 资格/权限不足（探针真机上就是这个 4）。
        // ⚠️ 别把 code 写死成判断依据 —— 只用来挑一句更贴切的话，
        //    认不出来就退回通用那句，照样把原始信息带上。
        if ns.domain.contains("CallKit") {
            return "苹果那套来电界面调不出来（这台签名没给通话资格，code \(ns.code)）。"
                + "现在用的是 Aevis 自己的通话页，通话本身是好的。"
        }
        return "苹果那套来电界面调不出来。现在用的是 Aevis 自己的通话页，通话本身是好的。"
    }

    // MARK: - 挂断

    func hangUp() {
        guard let manager else { return }
        // 先把自己这边的引用清掉 —— 这样系统回调进来再触发一次 `hangUp()`
        // 会在上面那句 `guard` 直接收住，不会转圈。
        self.manager = nil
        manager.delegate = nil
        let uuid = conversationUUID
        connectedReportedFor = nil

        Task {
            // ⚠️ **没有** `endConversation(uuid:)` 这个方法（第一次就是这么写错的）。
            //    正解是再走一次 `perform`，把 `EndConversationAction` 派给系统。
            try? await manager.perform([EndConversationAction(conversationUUID: uuid)])
            // `invalidate()` 会顺手把还挂着的会话全结束掉，比只置 nil 干净。
            manager.invalidate()
        }
    }

    // MARK: - 把「已接通」报给系统
    //
    // ## 🔴 这是「灵动岛上的通话时长一直是 0 秒」的根因（用户 2026-10-02 报的）
    //
    // 系统界面上那个计时器 = 现在 − **我们报上去的接通时刻**。
    // 而 `reportConversationEvent` 要的是 `Conversation` **对象**（不是 uuid），
    // 所以得先在 `manager.conversations` 里把它找出来。
    //
    // 老代码是这样的：
    //     if let conversation = manager.conversations.first(where: { $0.uuid == … }) {
    //         reportConversationEvent(.conversationStartedConnecting(.now), for: conversation)
    //         reportConversationEvent(.conversationConnected(.now), for: conversation)
    //     }
    // —— **只在 `perform` 回调那一刻找一次**，找不到就两个事件全都不报。
    // 而那一刻会话经常还没登记进列表（系统是异步建的），
    // 于是系统永远收不到"接通"，那张卡的计时器就一直停在 0:00。
    // 这也正好解释了用户为什么说"**有时候**是 0 秒"——是个竞态。
    //
    // 苹果自己的示例（Initiating VoIP conversations with LiveCommunicationKit）
    // 就是靠"等一下再找"绕开它的：
    //     try await manager.perform([action])
    //     Task { try await Task.sleep(for: .seconds(1)); for c in manager.conversations { … } }
    //
    // 这里做得更稳一点：立刻试一次，然后每 0.3 秒重试，最多 15 次（约 4.5 秒）。
    // 另外 `conversationChanged` 里还有一条兜底（会话主动撞上来时补报）。
    // 两条路都留着 ——"会话什么时候才登记好"这件事系统没给任何保证。

    /// 把「已接通」补报给系统。找不到会话就等一会儿再来。幂等。
    private func reportConnected(attemptsLeft: Int = 15) {
        guard let manager else { return }
        guard connectedReportedFor != conversationUUID else { return }

        if let conversation = manager.conversations.first(where: { $0.uuid == conversationUUID }) {
            manager.reportConversationEvent(.conversationConnected(.now), for: conversation)
            connectedReportedFor = conversationUUID
            BlackBox.log("📞 系统通话界面：已报「接通」（第 \(16 - attemptsLeft) 次尝试）")
            return
        }

        guard attemptsLeft > 0 else {
            // 等到这里说明会话一直没进列表 —— 系统卡的计时器不会走。
            // 记下来，下次真机对账时这一行就是现场。
            BlackBox.log("📞 系统通话界面：一直没等到会话，系统卡的计时器不会走")
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.reportConnected(attemptsLeft: attemptsLeft - 1)
        }
    }

    // MARK: - 把 App 这边的静音**推给系统那张卡**
    //
    // ## 为什么只能走 `perform`
    // LiveCommunicationKit **没有** `setMuted` 这类接口，`Conversation.Event` 一共
    // 也只有 4 个（connected / ended / startedConnecting / updated）——
    // **没有一个能表达"静音了"**。所以唯一能往系统那张卡同步状态的通路就是
    // `perform`（"请系统去做这件事"），也就是我们挂断时用的那条。
    //
    // ⚠️ 失败**静默**：卡上那个小指示灯没跟上，比让整通电话出毛病轻得多。
    //    真正保证两边不脱节的是**反方向**（系统卡按静音派回来的
    //    `MuteConversationAction`，见 `perform action:`）。
    // ⚠️ 这条路在真机上到底推不推得动**还没验过**（本机没 Xcode），
    //    所以它是锦上添花；`CallService.setMuted` 那边也带着 `pushToSystem`
    //    开关，系统派回来时不会再推一遍（免得自己跟自己对讲）。

    /// 把静音状态推给系统那张卡。
    func pushMuted(_ value: Bool) {
        guard let manager,
              manager.conversations.contains(where: { $0.uuid == conversationUUID }) else { return }
        let action = MuteConversationAction(conversationUUID: conversationUUID, isMuted: value)
        Task {
            try? await manager.perform([action])
        }
    }

    /// 系统那边（锁屏 / 灵动岛上的"结束"按钮）把通话挂了。
    /// **必须把我们的通话一起收掉** —— 不然麦克风还开着，ta会继续听你说。
    fileprivate func systemDidEnd() {
        teardown()
        // ⚠️ 必须带 `fromSystem: true`：带上它才会发信号，把**通话页**也收掉。
        //    用户报的「挂断 APP 同步不了」就是这个 ——
        //    通话页挂在 `AppRouter.showCall` / `CompanionCard` 自己的 `showCall` 上，
        //    只把 `CallService.state` 置回 idle 是**不会关页面**的。
        CallService.shared.hangUp(fromSystem: true)
    }

    private func teardown() {
        manager?.delegate = nil
        manager?.invalidate()
        manager = nil
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var out = "\(ns.domain) \(ns.code)｜\(ns.localizedDescription)"
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String, !reason.isEmpty {
            out += "｜原因：\(reason)"
        }
        return out
    }
}

// MARK: - ConversationManagerDelegate
//
// ⚠️⚠️ 这个协议一共 **7 个 required 方法**，少一个就编译不过，
// 而且报错会指到"argument labels 不一样"上，很容易看歪
// （探针第一轮就栽在这：以为 `perform:` 名字写错了，其实是别的没实现）。
// 必须全的：DidBegin / DidReset / conversationChanged / didActivate /
// didDeactivate / perform / timedOutPerforming。
//
// ⚠️ **不能用 `@MainActor` 包这个 extension**（协议方法不是主 actor 隔离的），
// 所以里面动任何东西一律 `Task { @MainActor in … }`。
@available(iOS 17.4, *)
extension SystemCallCenter: ConversationManagerDelegate {

    nonisolated func conversationManagerDidBegin(_ manager: ConversationManager) {
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：manager 起来了")
        }
    }

    nonisolated func conversationManagerDidReset(_ manager: ConversationManager) {
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：manager 被系统重置了")
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        conversationChanged conversation: Conversation
    ) {
        let state = String(describing: conversation.state)
        let uuid = conversation.uuid
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：状态 → \(state)")
            // 兜底：会话一旦出现在列表里就补报「接通」。
            // `reportConnected` 那条是**主动去追**，这里是它**撞上来** ——
            // 「会话什么时候才登记好」系统没给保证，两条路都留着才稳。
            guard uuid == self.conversationUUID,
                  self.connectedReportedFor != uuid,
                  let manager = self.manager,
                  let hit = manager.conversations.first(where: { $0.uuid == uuid }) else { return }
            manager.reportConversationEvent(.conversationConnected(.now), for: hit)
            self.connectedReportedFor = uuid
            BlackBox.log("📞 系统通话界面：会话出现时补报了「接通」")
        }
    }

    /// 系统把音频会话交给通话了 —— 说明界面**真的弹出来了**。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：音频会话已激活")
            // ⚠️ 系统很可能顺手把会话类别改成它自己那套，而我们这边正靠
            //    `.playAndRecord` 收着麦克风 —— 被改掉就是「ta听不见你说话了」。
            //    补一次。（只在通话进行中生效，挂断后是空操作。）
            CallService.shared.reassertAudioIfActive()
        }
    }

    nonisolated func conversationManager(
        _ manager: ConversationManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：音频会话放开了")
        }
    }

    /// 系统把"用户/系统发起的动作"派回来。
    /// 我们主动拨出时，**系统界面弹出来那一下就会回调这里**（走 `.start` 那支）。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        perform action: ConversationAction
    ) {
        // ⚠️ 必须 fulfill（或 fail），否则系统会一直等我们，
        //    那个"通话"卡在半空中，用户看到的是一个转不出去的界面。
        switch action {
        case let start as StartConversationAction:
            // 真实通话的媒体流是在这里接上的；我们只要"接通"这个状态 ——
            // 声音走的是我们自己的 `ListenService` + `SpeechService`。
            //
            // ⚠️ **这里只报「开始连接」**（它说的是"我们发起了"，不依赖系统把会话
            //    登记好）。「已接通」交给 `reportConnected()` —— 那条会一直重试到
            //    找到会话为止。老代码把两个事件挤在同一个 `if let` 里同步报，
            //    找不到会话就**两个都不报** ⇒ 系统卡的计时器永远停在 0:00。
            // ⚠️ `reportConversationEvent` 要的是 `Conversation` **对象**，不是 uuid。
            if let conversation = manager.conversations.first(where: { $0.uuid == start.conversationUUID }) {
                manager.reportConversationEvent(.conversationStartedConnecting(.now), for: conversation)
            }
            start.fulfill(dateStarted: .now)
            Task { @MainActor in self.reportConnected() }

        case let end as EndConversationAction:
            // 用户在系统界面（锁屏 / 灵动岛）上按了挂断。
            end.fulfill(dateEnded: .now)
            Task { @MainActor in self.systemDidEnd() }

        case let mute as MuteConversationAction:
            // 用户在系统界面上按了静音 / 取消静音。
            //
            // ⚠️ `isMuted` 是**目标状态**（true = 要静音，false = 要取消静音），
            //    不是"切换一下"。老代码写的是 `if !CallService.shared.muted { toggleMute() }`
            //    —— 单向：取消了静音这一支**整段跳过**，于是"点了取消没用"。
            let want = mute.isMuted
            Task { @MainActor in
                // ⚠️ `pushToSystem: false` —— 这是系统派回来的，
                //    别再推回去（见 `CallService.setMuted` 的参数说明）。
                CallService.shared.setMuted(want, pushToSystem: false)
            }
            mute.fulfill()

        default:
            action.fulfill()
        }
    }

    /// 系统等我们 fulfill 等到超时 —— 这是"卡住"的信号，要留下来。
    nonisolated func conversationManager(
        _ manager: ConversationManager,
        timedOutPerforming action: ConversationAction
    ) {
        let name = String(describing: type(of: action))
        Task { @MainActor in
            BlackBox.log("⚠️ 系统通话界面：动作超时 \(name)")
        }
    }
}

#endif
