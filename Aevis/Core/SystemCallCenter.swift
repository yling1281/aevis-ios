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
/// 所以先出了 `AevisCallProbe`（`https://sucai.apekin.com/CallProbe-3086.ipa`），
/// 这里是把探针里**验证过能编过的那套用法原样搬过来**。
///
/// ## 两条路，我们只走一条
/// | 路 | 要不要 PushKit 推送 |
/// |---|---|
/// | **收来电** `reportNewIncomingConversation` | ✅ **必须**（文档原话：不报告系统会**杀掉 App**） |
/// | **主动拨出** `StartConversationAction` | ❌ **不要** |
///
/// 我们走的是"**你拨给 TA**"这条 —— 不需要推送服务器、不需要后端、不需要上架。
/// 「她打给你」那条走的是**本地通知**（见 `ProactiveService`），不是这条路：
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
    private var displayName = "TA"

    // MARK: - 拨出

    func start(displayName: String) {
        self.displayName = displayName.isEmpty ? "TA" : displayName
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
                BlackBox.log("📞 系统通话界面：请求已发出（等系统回话）")
            } catch {
                // ⚠️ 这里**只记一笔**，不弹任何提示、不打断通话。
                //
                // 系统不给界面（这套侧载签名没继承通话资格 / 描述文件里没有
                // `aps-environment`）是**预期内**的结果之一。
                // 我们自己的通话界面还在正常跑，用户那边完全无感 ——
                // 为了"灵动岛上没出那张卡"去打断一通正在进行的电话，那是本末倒置。
                BlackBox.failure("📞 系统通话界面不可用（退回自己的界面）",
                                 detail: Self.describe(error))
                self.teardown()
            }
        }
    }

    // MARK: - 挂断

    func hangUp() {
        guard let manager else { return }
        // 先把自己这边的引用清掉 —— 这样系统回调进来再触发一次 `hangUp()`
        // 会在上面那句 `guard` 直接收住，不会转圈。
        self.manager = nil
        manager.delegate = nil
        let uuid = conversationUUID

        Task {
            // ⚠️ **没有** `endConversation(uuid:)` 这个方法（第一次就是这么写错的）。
            //    正解是再走一次 `perform`，把 `EndConversationAction` 派给系统。
            try? await manager.perform([EndConversationAction(conversationUUID: uuid)])
            // `invalidate()` 会顺手把还挂着的会话全结束掉，比只置 nil 干净。
            manager.invalidate()
        }
    }

    /// 系统那边（锁屏 / 灵动岛上的"结束"按钮）把通话挂了。
    /// **必须把我们的通话一起收掉** —— 不然麦克风还开着，她会继续听你说。
    fileprivate func systemDidEnd() {
        teardown()
        CallService.shared.hangUp()
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
        Task { @MainActor in
            BlackBox.log("📞 系统通话界面：状态 → \(state)")
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
            //    `.playAndRecord` 收着麦克风 —— 被改掉就是「她听不见你说话了」。
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
            // ⚠️ `reportConversationEvent` 要的是 `Conversation` **对象**，不是 uuid。
            if let conversation = manager.conversations.first(where: { $0.uuid == start.conversationUUID }) {
                manager.reportConversationEvent(.conversationStartedConnecting(.now), for: conversation)
                manager.reportConversationEvent(.conversationConnected(.now), for: conversation)
            }
            start.fulfill(dateStarted: .now)

        case let end as EndConversationAction:
            // 用户在系统界面（锁屏 / 灵动岛）上按了挂断。
            end.fulfill(dateEnded: .now)
            Task { @MainActor in self.systemDidEnd() }

        case let mute as MuteConversationAction:
            // 用户在系统界面上按了静音 —— 跟着我们的麦克风一起动，
            // 不然"界面上显示静音了、麦克风却还开着"，那是骗人。
            Task { @MainActor in
                if CallService.shared.state == .active, !CallService.shared.muted {
                    CallService.shared.toggleMute()
                }
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
