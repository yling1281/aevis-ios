import Foundation
import UserNotifications
import Intents

#if canImport(UIKit)
import UIKit
#endif

enum BarkError: LocalizedError {
    case notConfigured
    case badURL
    case rejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有填 Bark 地址。"
        case .badURL:
            return "Bark 地址格式不对。应该是 https://api.day.app/你的KEY 这样。"
        case let .rejected(code, message):
            if code == 400 {
                return "Bark 说地址或参数不对（400）。检查 KEY 有没有抄错。"
            }
            return "Bark 返回 \(code)：\(message)"
        }
    }
}

/// 让 ta 主动找你。
///
/// 现实约束（必须先讲清楚）：
/// - 侧载的 App 用不了苹果的系统推送（没有对方的 APNs 密钥），所以主动消息靠**本地通知**，
///   它是系统级的，App 不运行也照样到点弹出来。
/// - 但「不定时」不能真的随机：本地通知只能在排程时把时间定下来。
///   所以做法是**每次打开 App 时，为接下来 24 小时重新随机排一批**。
/// - ta说的话不能临时生成（后台跑不了模型），所以是**提前生成一批存起来**，
///   排程时轮流取用。没填 API Key 时用内置兜底话术。
final class ProactiveService {
    static let shared = ProactiveService()

    private let center = UNUserNotificationCenter.current()
    private static let idPrefix = "aevis.proactive."

    // MARK: - 通知分类（那个「直接在通知上回ta」的输入框）
    //
    // 用户 2026-09-30：「能不能专门弄一个 IPA 给它弄通知……那样子感觉会很好玩」。
    //
    // ⚠️ **不用第二个 IPA**。iOS 不允许一个 App 让另一个 App 弹通知；
    //    而"通知 App"自己不在运行时，收不到任何信号（没有 APNs 付费账号的话）。
    //    真能把通知变得像"ta发消息"的，是下面这两样：
    //      ① 分类 + 输入框 → **不打开 App 直接在通知上打字回ta**；
    //      ② `INSendMessageIntent` → 横幅顶上显示**ta的头像和名字**。

    /// 通知上那个「回一句」用的分类 id。
    /// ⚠️ 分类是**跟系统注册**的，不是跟单条通知走的 —— 漏注册就没有输入框。
    static let replyCategory = "aevis.reply"

    /// 「直接回复」那个动作的 id。代理里靠它认出"用户是打字回的"。
    static let replyAction = "aevis.reply.send"

    // MARK: - 「ta趁你不在时打给你」
    //
    // 用户 2026-10-01：问「通话哪一块」时答「苹果系统来电界面，然后**第一个也要**」。
    // 「第一个」就是「ta趁你不在时打给我」—— 一条像来电的通知，上面有「接听」。
    //
    // ⚠️ 这条**走本地通知，不是 LiveCommunicationKit 的收来电那条路**。
    //    那一条（`reportNewIncomingConversation`）**必须**有 PushKit VoIP 推送
    //    （文档原话：不报告系统会杀掉 App），而侧载包没有 APNs 付费账号，
    //    根本喂不到我们手上。所以「ta打给你」只能是我们自己弹的一条通知 ——
    //    点「接听」之后**进我们自己的通话界面**（那时可以再调系统界面，见 `SystemCall`）。

    /// 「ta打给你」那条通知的分类 id。
    static let callCategory = "aevis.call"

    /// 通知上那两个按钮。
    static let callAcceptAction = "aevis.call.accept"
    static let callDeclineAction = "aevis.call.decline"

    /// 注册通知分类。幂等，重复调没有副作用。
    ///
    /// 时机：**App 启动时**（`AevisApp.init`）+ 每次重排时都调一次。
    static func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction,
            title: "回一句",
            options: [],
            textInputButtonTitle: "发出去",
            textInputPlaceholder: "说点什么…"
        )
        let replyCategory = UNNotificationCategory(
            identifier: Self.replyCategory,
            actions: [reply],
            // ⚠️ 别删这一行：把分类和 `INSendMessageIntent` 绑在一起，
            //    系统才会把这条通知当成"和这个人的会话"。
            intentIdentifiers: ["INSendMessageIntent"],
            options: []
        )

        // 「接听」要 `.foreground` —— 用户点它的意思就是"我要进通话页面"，
        // 不该只把通知清掉然后什么都不发生。
        let accept = UNNotificationAction(
            identifier: callAcceptAction,
            title: "接听",
            options: [.foreground]
        )
        let decline = UNNotificationAction(
            identifier: callDeclineAction,
            title: "不用了",
            options: [.destructive]
        )
        let callCategory = UNNotificationCategory(
            identifier: Self.callCategory,
            actions: [accept, decline],
            intentIdentifiers: ["INSendMessageIntent"],
            options: []
        )

        // ⚠️⚠️ `setNotificationCategories` 是**整份替换**，不是追加。
        //      这里少写一个分类，那个分类就会从系统里消失 ——
        //      而且是**静默**的（通知照弹，只是按钮和输入框没了）。
        UNUserNotificationCenter.current().setNotificationCategories([
            replyCategory,
            callCategory
        ])
    }

    private init() {}

    // MARK: - 授权

    /// 请求通知权限。**只在用户主动去打开「主动消息」的时候调** ——
    /// 一进 App 就弹系统框太打扰，截图自检时还会盖住大半个界面。
    func ensureAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    /// 现在到底能不能发通知 —— **只问，不弹框**。
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: - 排程

    /// 按当前设置重排全部主动消息。任何时候调用都安全（会先清掉旧的）。
    func reschedule() async {
        let settings = AppSettings.shared
        let persona = PersonaStore.shared.persona
        // 「这些话说给谁听」—— 排程时把当前联系人记在通知里，
        // 弹出来之后好落回**对的那个会话**。
        // ⚠️ 回主线程读：`ChatStore` 是 `@Published`，在后台读它
        //    跟后台写一样会让 SwiftUI 收到别的线程的通知，iOS 26 上会崩（踩过）。
        let owner = await MainActor.run { ChatStore.shared.currentContactID?.uuidString }

        // ta的头像 —— 通知里要能一眼看出"是ta"，不是一个冷冰冰的 App 名。
        // ⚠️ 回主线程读：`PersonaStore` 跟 `ChatStore` 一样是主线程隔离的。
        let avatarData = await MainActor.run { () -> Data? in
            guard let owner, let id = UUID(uuidString: owner) else { return nil }
            return PersonaStore.shared.avatar(for: id)?.jpegData(compressionQuality: 0.8)
        }

        center.removePendingNotificationRequests(
            withIdentifiers: await pendingProactiveIdentifiers()
        )

        // ⚠️ 两个开关在这里是**并列**的，不是父子。
        //
        // 原来这一句是 `guard settings.proactiveEnabled else { return }` ——
        // 加了「ta打给你」之后那样就不对了：一个"只想接ta电话、不想收ta消息"
        // 的人永远排不上来电。所以总开关只管文字消息那两块（见下面各自的 `if`），
        // 来电由 `callEnabled` 单独管。
        guard settings.proactiveEnabled || settings.callEnabled else { return }

        // ⚠️ 这里**不再请求权限**，只检查有没有。
        //
        // 原来是在这儿调 ensureAuthorization() —— 结果每次启动都弹一次系统框：
        // 一进 App 就被问「要不要通知」很打扰；截图自检时那个框还会一直挂在
        // 屏幕上，把后面几张截图全盖住（真的是看截图才发现的）。
        //
        // 授权这件事应该由用户**主动**触发 —— 见「主动消息」卡片里那个按钮。
        #if DEBUG
        // 截图自检时不排程，省得启动路径上多出别的系统框
        if ProcessInfo.processInfo.arguments.contains("-aevisDemo") { return }
        #endif

        guard await isAuthorized() else { return }

        // 分类注册一遍（幂等）。它决定通知上有没有那个「回一句」的输入框。
        Self.registerCategories()
        // 上一轮那些附件已经随 pending 通知一起作废了，先扫干净。
        Self.clearAvatarCache()

        let lines = await linePool(persona: persona, settings: settings)

        var cursor = 0
        func nextLine() -> String {
            guard !lines.isEmpty else { return Self.fallbackLines[0] }
            let text = lines[cursor % lines.count]
            cursor += 1
            return text
        }

        // 定时：每天固定几个点，用重复触发器
        if settings.proactiveEnabled, settings.fixedTimesEnabled {
            for (index, time) in settings.fixedTimes.enumerated() {
                guard let (hour, minute) = Self.parse(time) else { continue }
                let content = makeContent(
                    title: persona.name.isEmpty ? "Aevis" : persona.name,
                    body: nextLine(),
                    owner: owner,
                    avatarData: avatarData
                )
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let request = UNNotificationRequest(
                    identifier: Self.idPrefix + "fixed." + String(index),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }

        // 不定时：为接下来 24 小时随机排几条，一次性触发
        if settings.proactiveEnabled, settings.randomEnabled {
            let count = max(1, min(settings.randomPerDay, 6))
            let now = Date()
            for slot in 0..<count {
                // 把 24 小时分成 count 段，每段里随机取一个点，避免全挤在一起
                let windowLength = 24.0 * 3600.0 / Double(count)
                let offset = windowLength * Double(slot) + Double.random(in: 0..<windowLength)
                let fireAt = now.addingTimeInterval(max(offset, 300))
                let content = makeContent(
                    title: persona.name.isEmpty ? "Aevis" : persona.name,
                    body: nextLine(),
                    owner: owner,
                    avatarData: avatarData
                )
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: fireAt
                    ),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: Self.idPrefix + "random." + String(slot),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }

        // ⭐ 「ta趁你不在时打给你」（用户 2026-10-01 点名的「第一个也要」）。
        //
        // 一天 1~3 通，最晚也是"接下来 24 小时内"——
        // 本地通知只能在排程时把时间定下来，做不到真正的实时随机（跟上面一样）。
        // 每次回前台都会整批重排，所以它对人来说是"不知道什么时候会来"。
        if settings.callEnabled {
            let count = Int.random(in: 1...3)
            let now = Date()
            for slot in 0..<count {
                let windowLength = 24.0 * 3600.0 / Double(count)
                let offset = windowLength * Double(slot) + Double.random(in: 0..<windowLength)
                // ⚠️ 至少 20 分钟后：刚打开 App 就"ta来电"太假了，
                //    而且会跟用户手上正在做的事撞上。
                let fireAt = now.addingTimeInterval(max(offset, 1200))
                let content = makeContent(
                    title: persona.name.isEmpty ? "Aevis" : persona.name,
                    body: callLine(settings: settings),
                    owner: owner,
                    avatarData: avatarData,
                    category: Self.callCategory
                )
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: fireAt
                    ),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: Self.idPrefix + "call." + String(slot),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }

    /// 「ta打给你」那条通知上写什么。
    ///
    /// 复用「主动消息」那批话术（本来就是"ta会突然想对你说的话"），
    /// 一句都没准备的时候用专门的兜底 —— 兜底那几句是**暗示"接一下"**的，
    /// 因为这条通知上有「接听」按钮，正文得配得上。
    private func callLine(settings: AppSettings) -> String {
        if let line = settings.proactiveLines.randomElement(),
           !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // ⭐ 这句会写到「ta打给你」那条通知的正文上 —— 池里可能是旧文案，
            //    纯剥一次标记（不更新心情），别让标记露在来电通知上。
            return MoodStore.strippingMarker(from: line)
        }
        return Self.fallbackCallLines.randomElement() ?? "想给你打个电话"
    }

    /// 没填 API Key、或一句都没准备时，「ta打给你」用的兜底。
    static let fallbackCallLines: [String] = [
        "想给你打个电话，接一下嘛",
        "突然想听听你的声音",
        "有空吗，想跟你说说话",
        "想你了，方便接一下吗"
    ]

    private func pendingProactiveIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter {
                    $0.hasPrefix(Self.idPrefix)
                })
            }
        }
    }

    private func makeContent(title: String, body: String,
                             owner: String? = nil,
                             avatarData: Data? = nil,
                             category: String = ProactiveService.replyCategory) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // ta的话应该能穿透专注模式
        content.interruptionLevel = .timeSensitive
        // ⭐ 横幅上那个「回一句」的打字框 —— **不打开 App 就能跟ta说话**。
        //    「ta打给你」那一类挂的是另一个分类（上面有「接听 / 不用了」）。
        content.categoryIdentifier = category
        // ⚠️⚠️ **把正文塞进通知里带着走** —— 这是「弹窗消息要落进聊天记录」
        //    （用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的，像微信那样」）
        //    唯一可行的做法：本地通知在 App **没运行**的时候也在弹，那时候我们
        //    一行代码都执行不了。所以只能把这句话存在通知自己身上，
        //    等 App 一起来再补进聊天记录（见 `deliverPendingToChat`）。
        var info: [String: Any] = ["text": body]
        if let owner, !owner.isEmpty { info["persona"] = owner }
        // 标一下"这条是来电不是消息"。下面 `payload(fromRequest:)` 靠它
        // 把这一类挡在聊天记录外面 —— 来电不该变成聊天里的一行字。
        if category == Self.callCategory { info["kind"] = "call" }
        content.userInfo = info

        // ta的话得**看起来是ta说的**，而不是"某个 App 推了条消息"。
        // 两步，谁都可能失败，所以**一步都不许把通知本身带下水**：
        //   ① ta的头像挂成附件（本地通知一定生效）；
        //   ② 试 Communication Notification（要系统能力，失败就退回普通样式）。
        if let avatarData {
            Self.attachAvatar(avatarData, to: content, owner: owner)
        }
        return Self.upgradeToCommunication(content,
                                           owner: owner,
                                           name: title,
                                           avatarData: avatarData)
    }

    // MARK: - 让通知看起来是「ta」发的

    /// 通知附件的存放目录。
    ///
    /// ⚠️ **不能放 `tmp/`** —— 排程和真正弹出来可能差好几个小时，
    ///    而系统会清临时目录。放在 Application Support 下自己建的目录里最稳。
    private static func avatarDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AevisNotify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把ta的头像挂成通知附件 —— 通知里就能看到ta的脸。
    ///
    /// ⚠️ 附件只认**磁盘上的文件**（`UNNotificationAttachment` 不收 `UIImage`）。
    /// ⚠️⚠️ 而且它初始化时会把文件**移走**（不是复制）！所以**每条通知都得有自己的
    ///    文件** —— 共用同一个路径的话，从第二条起就找不到文件、附件静默失效。
    private static func attachAvatar(_ data: Data,
                                     to content: UNMutableNotificationContent,
                                     owner: String?) {
        guard owner != nil else { return }
        let url = avatarDirectory()
            .appendingPathComponent("notify-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            content.attachments = [
                try UNNotificationAttachment(identifier: "aevis.avatar", url: url, options: nil)
            ]
        } catch {
            // 挂不上就不挂。头像只是锦上添花，**绝不能因为它发不出通知**。
        }
    }

    /// 排程前把上一轮的附件扫干净。
    ///
    /// 调用点在 `reschedule()`：那上面刚把所有 pending 通知都清了，它们的附件
    /// 也就没人用了（已经弹出去的那些，系统早就把附件复制到自己的地方了）。
    private static func clearAvatarCache() {
        let manager = FileManager.default
        let dir = avatarDirectory()
        let names = (try? manager.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix("notify-") {
            try? manager.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// 试一次「像ta发来的消息」那种通知。
    ///
    /// iOS 15 起，通知可以借 `INSendMessageIntent` 变成**真人消息**的样式：
    /// 顶上显示**ta的头像 + 名字**（而不是 App 名），专注模式也会把它当成
    /// "联系人消息"放行。**这是唯一能改掉横幅顶上那个 App 名的办法。**
    ///
    /// ⚠️ **可能失败**：完整生效要「Communication Notifications」能力，
    ///    而侧载重签用的描述文件里未必有它。所以这里全程 `try?`，
    ///    失败就原样返回普通通知 ——
    ///    「通知发不出去」比「通知不够好看」严重得多。
    private static func upgradeToCommunication(_ content: UNMutableNotificationContent,
                                               owner: String?,
                                               name: String,
                                               avatarData: Data?) -> UNMutableNotificationContent {
        guard let owner, let id = UUID(uuidString: owner) else { return content }

        var components = PersonNameComponents()
        components.nickname = name
        let avatar = avatarData.map { INImage(imageData: $0) }

        let sender = INPerson(personHandle: INPersonHandle(value: id.uuidString, type: .unknown),
                              nameComponents: components,
                              displayName: name,
                              image: avatar,
                              contactIdentifier: nil,
                              customIdentifier: id.uuidString,
                              isMe: false,
                              suggestionType: .none)
        // 「我」这一头也得给一个 —— 缺了它 intent 会被系统判成无效。
        let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown),
                          nameComponents: nil,
                          displayName: nil,
                          image: nil,
                          contactIdentifier: nil,
                          customIdentifier: nil,
                          isMe: true,
                          suggestionType: .none)

        let intent = INSendMessageIntent(recipients: [me],
                                         outgoingMessageType: .outgoingMessageText,
                                         content: content.body,
                                        speakableGroupName: nil,
                                        conversationIdentifier: "aevis.chat." + id.uuidString,
                                        serviceName: "Aevis",
                                        sender: sender,
                                        attachments: nil)
        if let avatar {
            intent.setImage(avatar, forParameterNamed: \.sender)
        }

        // 让系统"认识"这个人 —— 专注模式的白名单、Siri 的建议都靠它。
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        guard let upgraded = try? content.updating(from: intent),
              let mutable = upgraded.mutableCopy() as? UNMutableNotificationContent else {
            return content
        }
        return mutable
    }

    private static func parse(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    // MARK: - 弹出来的话，补进聊天记录
    //
    // 用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的，像微信那样」
    //
    // 微信的行为是：通知弹出来，点进去**那条消息就在聊天里**。
    // 我们以前只弹通知、不落聊天 —— 用户点进去发现聊天里没有那句话，
    // 看起来就像"ta说的这句丢了"。
    //
    // 两条路都要走，少一条就有场景漏：
    //   ① App 正在前台 → 系统先交给代理（`willPresent`），当场落进聊天；
    //   ② App 没运行 / 在后台 → 通知自己弹出去，**等 App 一起来**扫一遍
    //      "已送达但还没进聊天"的通知，补进去（`deliverPendingToChat`）。

    /// 从一条通知里把「ta说了什么 + 说给谁」抠出来。
    static func payload(from notification: UNNotification) -> (text: String, owner: UUID?)? {
        payload(fromRequest: notification.request)
    }

    /// 同上，只是从 `request` 取。
    ///
    /// 单独开一个口子是因为**用户在通知上直接打字回复**时，递过来的是
    /// `UNNotificationResponse`（里面只有 `request`），而不是 `UNNotification`。
    static func payload(fromRequest request: UNNotificationRequest) -> (text: String, owner: UUID?)? {
        guard request.identifier.hasPrefix(idPrefix) else { return nil }
        // ⚠️ 「ta打给你」那条**不是消息**，绝不能进聊天记录 ——
        //    它有自己的路（`absorbForegroundCall` / `acceptCall`）。
        //    少了这一句，"ta来电"的话会变成聊天里孤零零的一行，
        //    而且用户点「接听」之后回到聊天还能看到它，莫名其妙。
        if request.content.categoryIdentifier == callCategory { return nil }
        let info = request.content.userInfo
        let text = (info["text"] as? String) ?? request.content.body
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let owner = (info["persona"] as? String).flatMap(UUID.init(uuidString:))
        return (text, owner)
    }

    /// 把「已经弹过、还没进聊天」的那几条补进去。
    ///
    /// 调用时机：App 启动、每次回到前台（`RootView`）。
    /// 处理完就把那条从"已送达"里删掉 —— 不删的话每次回前台都会重复补。
    @MainActor
    func deliverPendingToChat() async {
        let delivered = await center.deliveredNotifications()
        guard !delivered.isEmpty else { return }
        var handled: [String] = []
        for item in delivered {
            guard let payload = Self.payload(from: item) else { continue }
            ChatStore.shared.appendProactive(payload.text, for: payload.owner)
            handled.append(item.request.identifier)
        }
        if !handled.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: handled)
        }
    }

    /// 前台时系统先把通知交给我们（[`willPresent`]）—— 那就当场落进聊天。
    @MainActor
    func absorbForegroundNotification(_ notification: UNNotification) {
        guard let payload = Self.payload(from: notification) else { return }
        ChatStore.shared.appendProactive(payload.text, for: payload.owner)
        // 从"已送达"里删掉：不然回前台那次扫描会把它再补一遍。
        center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
    }

    // MARK: - 「ta打给你」：前台 / 点「接听」/ 点「不用了」

    /// 前台收到「ta打给你」。
    ///
    /// ⚠️ **不弹横幅**，改成在我们自己的界面上浮一条申请条
    /// （就是ta在聊天里主动申请打电话时那条一模一样的）——
    /// 用户正开着 App 看着屏幕，再弹一条系统横幅纯属噪音，而且点它还要多一次跳转。
    ///
    /// 返回 true 表示"这条我处理了"，代理那边就不用再走落聊天那条路。
    @MainActor
    func absorbForegroundCall(_ notification: UNNotification) -> Bool {
        guard notification.request.content.categoryIdentifier == Self.callCategory else {
            return false
        }
        center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
        CompanionRequest.shared.ask(.call, reason: notification.request.content.body)
        BlackBox.log("📞 ta在前台打给你 —— 改成界面上那条申请")
        return true
    }

    /// 用户点了「接听」（或直接点了通知本体）→ 进通话。
    ///
    /// ⚠️ 这里**只发一个跳转信号**，不自己去起通话：真正的 `CallService.start`
    ///    要麦克风权限、要主界面在，这些都不该在通知回调那几十秒里做。
    ///    冷启动也走这条 —— `AppRouter.showCall` 是状态，主界面一出现就消费它。
    @MainActor
    func acceptCall(from request: UNNotificationRequest) async {
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        BlackBox.log("📞 接了ta在后台打来的那通电话")
        AppRouter.shared.startCall()
    }

    /// 用户点了「不用了」。
    ///
    /// 只把这条通知收掉 —— **不写进聊天记录**（ta"想打给你"这件事不是一条消息），
    /// 也不给ta发什么。用户说的"不用了"就是不用了。
    @MainActor
    func dismissCallNotification(_ request: UNNotificationRequest) {
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])
        BlackBox.log("📞 ta打来的那通被拒了")
    }

    // MARK: - 用户在通知上直接回复
    //
    // ⭐ 2026-09-30。用户原话：「能不能专门弄一个 IPA 给它弄通知啊？就是本地联动……
    //    那样子感觉会很好玩」。
    //
    // **不用第二个 IPA** —— iOS 不允许一个 App 让另一个 App 弹通知，而"通知 App"
    // 自己不在运行时就收不到任何信号（侧载又没有 APNs 付费账号）。
    // 真正能实现"好玩"的是这条：**通知横幅上直接打字回ta，不用打开 App**。

    /// 用户在**通知上打字**回了ta一句。
    ///
    /// ⚠️ 这时候 App 多半在后台（甚至刚被系统冷启动），系统只给几十秒 ——
    ///    所以这里**只动数据、不碰界面**，而且每一步都不许抛错。
    ///
    /// 干两件事：
    ///   ① 两边的话都落进聊天（他回头打开 App 时，聊天里要是完整的）；
    ///   ② 让模型回一句再弹一条通知（不然他发完就干等，像没人搭理）。
    @MainActor
    func handleQuickReply(_ text: String, from request: UNNotificationRequest) async {
        // ⭐ owner 用**排程时定好**的那个（通知 `userInfo["persona"]` 里的），
        //    不是"回来时再取一次当前联系人" —— 用户在通知上回字之前可能已经切过人，
        //    那一刻的 `currentContactID` 未必是这条通知说给的人。
        //    只有老通知确实没带 owner 时，才退回当前联系人兜底。
        var owner = ChatStore.shared.currentContactID
        // ta刚才那句也得在聊天里 —— 它就是这条通知的内容。
        if let payload = Self.payload(fromRequest: request) {
            ChatStore.shared.appendProactive(payload.text, for: payload.owner)
            if let payloadOwner = payload.owner { owner = payloadOwner }
        }
        center.removeDeliveredNotifications(withIdentifiers: [request.identifier])

        ChatStore.shared.append(ChatMessage(role: .user, text: text), for: owner)

        // 后台时间有限：回复尽力而为。拿不到也没关系 ——
        // 用户那句已经存进去了，打开 App 正常聊一样接得上。
        guard let reply = await quickReply(to: text, owner: owner) else { return }
        ChatStore.shared.appendProactive(reply, for: owner)
        await scheduleInstantNotification(reply, owner: owner)
    }

    /// 用一次短调用替ta回一句（通知上那条不需要长篇大论）。
    ///
    /// - Parameter owner: **这条回复是说给谁听的**（= 那条通知排程时的联系人，
    ///   从通知 `userInfo["persona"]` 取出来、一路传进来）。**不许**在这里再取一次
    ///   "当前联系人" —— 用户点通知回字之前可能已经切过人了，那会把心情写到别人头上。
    @MainActor
    private func quickReply(to text: String, owner: UUID?) async -> String? {
        let settings = AppSettings.shared
        guard settings.isConfigured else { return nil }
        let persona = PersonaStore.shared.persona
        guard persona.isComplete else { return nil }

        var context = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        context.append(contentsOf: CoupleStore.shared.injectedLines())

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: settings.llm,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: text)],
                memory: context
            ) {
                collected += piece
                // 通知里塞不下长文；够一句就走。
                if collected.count > 200 { break }
            }
        } catch {
            return nil
        }
        // ⭐ 剥掉末尾的心情标记 —— 这句要弹成通知、还要落进聊天记录，
        //    标记一个字都不能露（本函数是 @MainActor，直接调 consume）。
        //    ⚠️ owner 传**排程时定好**的那个（不是当前联系人）。
        let trimmed = MoodStore.shared.consume(collected, owner: owner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 立刻弹一条通知（ta刚回的那句）。
    ///
    /// ⚠️ App 在**前台**时不弹 —— 用户正看着屏幕，再弹个横幅是噪音
    ///    （跟 `willPresent` 那条口径一致：前台的话系统自己会走 `willPresent`）。
    private func scheduleInstantNotification(_ text: String, owner: UUID?) async {
        let state = await MainActor.run { UIApplication.shared.applicationState }
        guard state != .active else { return }

        let persona = await MainActor.run { PersonaStore.shared.persona }
        let avatarData = await MainActor.run { () -> Data? in
            guard let owner else { return nil }
            return PersonaStore.shared.avatar(for: owner)?.jpegData(compressionQuality: 0.8)
        }
        let content = makeContent(title: persona.name.isEmpty ? "Aevis" : persona.name,
                                  body: text,
                                  owner: owner?.uuidString,
                                  avatarData: avatarData)
        // trigger 给 nil = 立刻送达。
        let request = UNNotificationRequest(identifier: Self.idPrefix + "reply." + UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        try? await center.add(request)
    }

    // MARK: - 话术池

    /// 取话术池；不够就先让模型写一批，写不出来用内置兜底。
    func linePool(persona: Persona, settings: AppSettings) async -> [String] {
        if settings.proactiveLines.count >= 4 {
            // ⭐ 话术池是持久化的，可能还存着「早先那版没剥过标记」的旧句子 ——
            //    取出来顺手纯剥一遍（不更新心情：这是回放旧文案，不是ta刚说的）。
            return settings.proactiveLines.map { MoodStore.strippingMarker(from: $0) }
        }
        if settings.isConfigured {
            let generated = await generateLines(
                persona: persona,
                config: settings.llm,
                count: 8
            )
            if generated.count >= 2 {
                settings.proactiveLines = generated
                return generated
            }
        }
        settings.proactiveLines = Self.fallbackLines
        return Self.fallbackLines
    }

    /// 让模型写一批「ta会突然想对你说的话」。
    func generateLines(persona: Persona, config: LLMConfig, count: Int) async -> [String] {
        let prompt = """
        你叫\(persona.name)。用你自己的口吻写 \(count) 句「突然想对 ta 说的话」，
        就像平时聊天时你会主动发出去的那种消息。一句一行，不要编号，不要引号，不要解释。
        每句短一点，像真人发微信。
        """
        let history = [ChatMessage(role: .user, text: prompt)]

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: history
            ) {
                collected += piece
                if collected.count > 1200 { break }
            }
        } catch {
            return []
        }

        // ⭐ 先剥掉末尾的心情标记再拆句 —— 这批话会存进话术池、以后弹给用户看，
        //    标记不能混在里面。
        //    ⚠️ 这里是**给话术池代笔**，不是"ta此刻对某个人说的一句话"：话术池
        //       (`settings.proactiveLines`) 是**全局共享**的，生成一次给所有联系人复用，
        //       根本没有"这条属于谁"可言。所以**只剥、不写心情**（用纯剥
        //       `strippingMarker`，跟 `callLine` 一个口径）—— 硬塞一个 owner
        //       反而会把某个人的心情写脏。
        let stripped = MoodStore.strippingMarker(from: collected)
        let lines = stripped
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line -> String in
                var text = line
                for token in ["- ", "* ", "1. ", "\"", "「", "」"] {
                    text = text.replacingOccurrences(of: token, with: "")
                }
                // 去掉可能的行首序号
                while let first = text.first, first.isNumber {
                    text.removeFirst()
                }
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".、。 "))
                return text
            }
            .filter { !$0.isEmpty && $0.count <= 60 }

        return Array(lines.prefix(count))
    }

    /// 没填 API Key、或生成失败时用的兜底。
    static let fallbackLines: [String] = [
        "在干嘛呢",
        "突然想你了",
        "今天累不累",
        "记得喝水",
        "刚刚看到个东西想到你",
        "早点睡，别熬太晚",
        "有好好吃饭吗",
        "没什么事，就是想跟你说句话"
    ]

    // MARK: - Bark

    /// 往 Bark 推一条。地址形如 https://api.day.app/你的KEY ，也可自建。
    func sendBark(text: String, title: String, urlString: String) async throws {
        var base = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw BarkError.notConfigured }
        while base.hasSuffix("/") { base.removeLast() }

        guard let parsed = URL(string: base), let host = parsed.host, !host.isEmpty else {
            throw BarkError.badURL
        }
        // 设备 key 就是地址最后那一段：https://api.day.app/你的KEY
        let key = parsed.lastPathComponent

        // ——— 首选：POST + JSON ———
        //
        // 中文直接放在 JSON 正文里，**不用拼进 URL 做百分号转义**。
        // 之前走的是 `/<标题>/<内容>` 那种路径写法，中文会被转成一长串 %E5%…，
        // 用户看到的就是「符号转码」。
        if !key.isEmpty, let pushURL = URL(string: base + "/push") {
            var payload: [String: Any] = [
                "device_key": key,
                "title": title,
                "body": text,
                "group": "Aevis"
            ]
            payload["level"] = "timeSensitive"

            var request = URLRequest(url: pushURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            // 成功就到此为止；失败往下走兜底。
            // 用 `!= nil` 而不是 `if let result =`：返回值我们**根本不用**，
            // 绑定一个从来没人读的变量只会让编译器警告。
            if (try? await Self.perform(request)) != nil {
                return
            }
            // 失败就往下走兜底 —— 老版本 Bark 或自建服务可能没有 /push
        }

        // ——— 兜底：路径那种老写法（中文照旧要转义，但至少能用） ———
        guard var comps = URLComponents(string: base) else { throw BarkError.badURL }
        comps.path += "/" + Self.encode(title) + "/" + Self.encode(text)
        comps.queryItems = [
            URLQueryItem(name: "group", value: "Aevis"),
            URLQueryItem(name: "level", value: "timeSensitive")
        ]
        guard let url = comps.url else { throw BarkError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        _ = try await Self.perform(request)
    }

    /// 发一次请求，成功返回；失败抛出人话。
    private static func perform(_ request: URLRequest) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw BarkError.rejected(code: code, message: "")
        }
        // Bark 正常会返回 {"code":200,"message":"success"}
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = object["code"] as? Int,
           inner != 200 {
            let message = (object["message"] as? String) ?? ""
            throw BarkError.rejected(code: inner, message: message)
        }
        return true
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}


/// 通知代理。
///
/// 只干一件事：**App 正在前台时，把那条通知当场塞进聊天记录，且不弹横幅**。
/// 用户就在 App 里看着，再弹个横幅纯属噪音（微信也是这个行为）。
final class ProactiveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let shared = ProactiveNotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // ⭐ 「ta打给你」那条：**不弹横幅** —— 用户正开着 App 看屏幕，
        //    改成在我们自己的界面上浮一条「接听 / 不用了」的申请条。
        if await ProactiveService.shared.absorbForegroundCall(notification) { return [] }
        await ProactiveService.shared.absorbForegroundNotification(notification)
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // ⭐ 「ta打给你」（用户 2026-10-01 要的「第一个」）。
        //
        // ⚠️ 这一段要排在下面「直接打字回复」那条**前面**。
        //    来电挂的是另一个分类，本来撞不上，但顺序写死更稳 ——
        //    探针那一轮的教训：回调的顺序错了，掉进兜底分支是**静默**的。
        if response.notification.request.content.categoryIdentifier == ProactiveService.callCategory {
            if response.actionIdentifier == ProactiveService.callDeclineAction {
                await ProactiveService.shared.dismissCallNotification(response.notification.request)
            } else {
                // 「接听」和"直接点通知"都算接 —— 用户点它的意思就是"我要接这通"。
                // 冷启动也走这条：`AppRouter.showCall` 是状态，主界面一出现就消费它。
                await ProactiveService.shared.acceptCall(from: response.notification.request)
            }
            return
        }

        // ⭐ 用户在通知上**直接打字**回的那一句 —— 不打开 App 也能跟ta说话。
        //    这是通知这一块最像真人的地方（用户 2026-09-30 想要的那个"好玩"）。
        if response.actionIdentifier == ProactiveService.replyAction,
           let typed = response as? UNTextInputNotificationResponse {
            let text = typed.userText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                await ProactiveService.shared.handleQuickReply(
                    text,
                    from: response.notification.request
                )
                return
            }
        }
        // 用户点了通知 → 那条话必须已经在聊天里（点进来看得见）。
        await ProactiveService.shared.absorbForegroundNotification(response.notification)
    }
}
