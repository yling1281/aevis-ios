import Foundation

/// 把手机上的这段聊天**搬给电脑那块屏**（生态第二期）。
///
/// ## 分工（这条定了就别改）
/// · **手机是唯一的大脑**：消息、上下文、模型 key、记忆、工具全在手机上。
/// · **电脑只是块屏 + 一个键盘**：它打过来的话在这里生成回复，再流式回传。
///
/// 这么分有两个原因：
/// ① 老板定的「**模型钱玩家自己出**」—— key 在手机上，电脑端不用再配一遍；
/// ② ta在手机上有记忆、有工具、有情侣空间；电脑端要是自己再实现一套，
///    就会"变成另一个人"——**同一份账**才是这个功能的意义。
///
/// ## 协议（都装在 `relay` 信封的 `data` 里）
/// 手机 → 电脑：
/// ```
/// {"k":"state", "owner":"<uuid>", "name":"ta", "messages":[…]}
/// {"k":"append","owner":"<uuid>", "msg":{…}}
/// {"k":"typing","on":true|false}
/// {"k":"delta", "text":"半句"}
/// {"k":"done",  "id":"<uuid>", "text":"整句"}
/// {"k":"error", "message":"…"}
/// ```
/// 电脑 → 手机：
/// ```
/// {"k":"hello"}                              连上后打个招呼（我们回一份 state 快照）
/// {"k":"send", "cid":"<电脑生成的 id>", "text":"…"}
/// {"k":"ping"}                               保活
/// ```
///
/// ## ⚠️ 为什么 `done` 要带 `id`、`append` 也要带 `id`
/// ta的回复**同时**走两条路：`ChatStore.append` 触发 `append` 推送，
/// 以及这里手动发一条 `done`。两条的顺序不保证（都在主线程，但电脑那边是网络）。
/// 所以两边都带 `id`，**电脑端按 id 去重** —— 这样不管谁先到都不会冒出两个气泡。
final class PairChatBridge {

    static let shared = PairChatBridge()
    private init() {}

    private var started = false
    /// ta正在回这一句（同时只允许一句 —— 跟上手机上的行为一致）。
    private var generating = false
    /// 电脑那边正在看哪个会话。
    private var peerOwner: UUID?
    /// 这些 id 是"电脑自己发过来的"，**别再镜像回去** ——
    /// 否则电脑上会看到自己刚发的那条出现两次（一次本地的、一次同步回来的）。
    private var echoBack: Set<UUID> = []

    // MARK: - 开关

    /// App 启动时调一次（幂等）。
    func start() {
        guard !started else { return }
        started = true

        PairChannel.shared.onPayload = { [weak self] payload in
            // ⚠️ 回调在 WS 的后台队列上 —— 里面要碰 ChatStore / PersonaStore，
            //    那两个都是主线程隔离的（后台碰在 iOS 26 上会崩，真崩过）。
            DispatchQueue.main.async { self?.receive(payload) }
        }

        // ⚠️ 用 `addAppendListener`（**观察者表**），不是赋值 ——
        //    `AutoSync`（每句话同步到网盘）也挂在这上面，赋值会把对方顶掉。
        //    详见 `ChatStore.addAppendListener` 的注释。
        ChatStore.shared.addAppendListener { [weak self] message, owner in
            self?.note(message, owner: owner)
        }
    }

    // MARK: - 收（电脑 → 手机）

    private func receive(_ payload: [String: Any]) {
        guard let kind = payload["k"] as? String else { return }
        switch kind {
        case "hello":
            pushState()
        case "send":
            handleSend(payload)
        case "ping":
            PairChannel.shared.send(["k": "pong"])
        default:
            break
        }
    }

    /// 电脑发来一句「我要说这个」。
    private func handleSend(_ payload: [String: Any]) {
        let text = (payload["text"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let owner = PersonaStore.shared.activeID else {
            PairChannel.shared.send(["k": "error", "message": "手机上还没有选中的 ta。"])
            return
        }

        // ⚠️ 用**电脑给的那个 id** 落库。等会儿 `append` 回调过来时，
        //    才认得出"这条是我自己刚发出去的"，不会又同步回电脑。
        let cid = (payload["cid"] as? String).flatMap { UUID(uuidString: $0) } ?? UUID()
        echoBack.insert(cid)
        ChatStore.shared.append(ChatMessage(id: cid, role: .user, text: text), for: owner)

        generate(owner: owner)
    }

    // MARK: - 发（手机 → 电脑）

    /// 手机上多了一条消息 → 推给电脑。
    /// ⚠️ 由 `ChatStore.append` **同步**调进来（主线程）。
    private func note(_ message: ChatMessage, owner: UUID?) {
        guard PairChannel.shared.state == .online else { return }
        // 电脑自己发来的那条：不回推
        if echoBack.remove(message.id) != nil { return }
        // 流式期间的"空占位"（ta还在想）不推 —— 那不是一句话
        if message.role == .assistant, message.text.isEmpty { return }
        // 只同步电脑正在看的那个会话
        let target = owner ?? PersonaStore.shared.activeID
        guard let target, target == (peerOwner ?? PersonaStore.shared.activeID) else { return }
        PairChannel.shared.send([
            "k": "append",
            "owner": target.uuidString,
            "msg": Self.wire(message)
        ])
    }

    /// 把当前会话**整份**推过去（电脑刚连上时用）。
    func pushState() {
        let active = PersonaStore.shared.active
        let owner = active?.id
        peerOwner = owner
        let list = ChatStore.shared.messages
        PairChannel.shared.send([
            "k": "state",
            "owner": owner?.uuidString ?? "",
            "name": Self.displayName(active),
            "messages": list.suffix(200).map { Self.wire($0) }
        ])
    }

    /// 电脑那边顶栏上显示的名字。
    ///
    /// ⚠️ `PersonaStore.active` 给的是 `Contact`，**它没有 `name`** ——
    ///    名字在 `contact.persona.name`（`Contact.displayName` 在空名字时会返回
    ///    "还没起名字"，那是给手机上通讯录列表用的文案，写给电脑看很怪）。
    ///    2026-10-03 CI 编译就挂在这一行（`value of type 'Contact' has no member 'name'`），
    ///    本地没有 Xcode，静态检查也查不出这个 —— **只能靠 CI 编**。
    private static func displayName(_ contact: Contact?) -> String {
        let name = contact?.persona.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? Pronoun.current : name
    }

    // MARK: - 让ta回

    /// 在手机上把这句话生成出回复，**流式**回传给电脑。
    ///
    /// ⚠️ 为什么是流式：电脑那边要的就是打字机那种"一个字一个字冒出来"，
    ///    一次性给一整段就没了那个味道（`ChatView` 在手机上也是流式）。
    private func generate(owner: UUID) {
        guard !generating else {
            PairChannel.shared.send(["k": "error", "message": "\(Pronoun.current)还在回上一句…"])
            return
        }
        generating = true
        PairChannel.shared.send(["k": "typing", "on": true])

        Task { @MainActor in
            defer { generating = false }

            let settings = AppSettings.shared
            let persona = PersonaStore.shared.persona
            let history = ChatStore.shared.messages.filter { $0.goesToModel }

            var context = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
            context.append(contentsOf: CoupleStore.shared.injectedLines())
            // 跟 QQ 那条一个套路（见 `QQBotService`）：让ta知道现在是在**电脑上**说话。
            context.append("现在你在电脑上跟他说话（手机放在一边没动）。"
                           + "回复要短、要像平时发消息那样，别写成一大段。")

            var collected = ""
            do {
                for try await piece in LLMService.streamReply(
                    config: settings.llm,
                    systemPrompt: persona.systemPrompt,
                    history: history,
                    memory: context,
                    tools: DeviceTools.all()
                ) {
                    collected += piece
                    PairChannel.shared.send(["k": "delta", "text": piece])
                }
            } catch {
                PairChannel.shared.send(["k": "typing", "on": false])
                PairChannel.shared.send(["k": "error",
                                         "message": error.localizedDescription])
                return
            }
            PairChannel.shared.send(["k": "typing", "on": false])

            // ⭐ 剥掉末尾的心情标记：这句既要落手机的聊天记录，又要整段推给电脑那块屏。
            //    这一整段跑在 `Task { @MainActor in }` 里，直接调 `consume`（顺带更新心情）。
            let cleaned = MoodStore.shared.consume(collected)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }

            let message = ChatMessage(role: .assistant, text: cleaned)
            ChatStore.shared.append(message, for: owner)
            // `append` 已经触发过一条 `append` 推送了；这条 `done` 只是让电脑把
            // 那个"流式气泡"定稿（两边都带 id，电脑端按 id 合并）。
            PairChannel.shared.send(["k": "done",
                                     "id": message.id.uuidString,
                                     "text": cleaned])

            // 聊够一段顺手提炼长期记忆（跟 App 里聊天之后那一步一样）。
            if settings.memoryEnabled {
                await MemoryStore.shared.extractIfNeeded(
                    config: settings.llm,
                    messages: ChatStore.shared.messages,
                    persona: persona
                )
            }
        }
    }

    // MARK: - 零件

    /// 把一条消息压成"省流"的形状发给电脑。
    ///
    /// ⚠️ **图片只发个标记，不发字节**：一张图几十上百 KB，base64 之后更大，
    ///    而电脑端现在也没有看图的地方。真要做"电脑上也能看图"，
    ///    得先有一个像 `AttachmentService` 那样的按需拉取 —— 那是下一步。
    private static func wire(_ message: ChatMessage) -> [String: Any] {
        var out: [String: Any] = [
            "id": message.id.uuidString,
            "role": message.role.rawValue,
            "text": message.text,
            "at": message.date.timeIntervalSince1970
        ]
        if message.imageData != nil { out["image"] = true }
        if message.kind == .voice { out["voice"] = message.voiceDuration ?? 0 }
        if message.kind == .call { out["call"] = true }
        if message.kind == .transfer, let info = message.transfer {
            out["transfer"] = [
                "amount": info.amount,
                "note": info.note,
                "red": info.isRedPacket,
                "accepted": info.accepted,
                "declined": info.declined
            ]
        }
        return out
    }
}
