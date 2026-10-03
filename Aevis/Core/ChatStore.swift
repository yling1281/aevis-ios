import Foundation

/// 对话记录。全部存在这台设备上。
///
/// **每个联系人一份对话。** 切联系人的时候把对应那份换进 `messages`，
/// 外面看到的就是「现在这个人的聊天记录」——
/// 所以项目里那些 `ChatStore.shared.messages` 的地方一行都不用改。
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    /// 当前联系人的消息（老入口，保持不变）。
    @Published private(set) var messages: [ChatMessage] = []

    /// 每个人的消息分开放，按联系人 id 归。
    private var byContact: [UUID: [ChatMessage]] = [:]
    private var currentID: UUID?

    /// 「现在这个会话是说给谁听的」—— 排程主动消息时要把它记在通知身上，
    /// 弹出来之后才知道该落回**哪个**会话（见 `ProactiveService.makeContent(owner:)`）。
    ///
    /// ⚠️ **只在主线程读。** `ChatStore` 是 `ObservableObject`，
    ///    在后台读它的状态和后台写一样，会让 SwiftUI 收到别的线程的通知，
    ///    iOS 26 上会崩（真崩过）。外面请这样用：
    ///    `await MainActor.run { ChatStore.shared.currentContactID }`
    ///
    /// 为什么不直接把 `currentID` 改成 `private(set)`：那样任何地方都能读，
    /// 上面那条"主线程"的约定就只靠自觉了。给个起了名字的口子，
    /// 读的人会先看到这句警告。
    var currentContactID: UUID? { currentID }

    private let fileURL: URL
    private let legacyFileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-chats.json")
        legacyFileURL = base.appendingPathComponent("aevis-messages.json")
        load()
    }

    // MARK: - 切人

    /// 正在「搬家」导入 / 启动读档。
    ///
    /// ⚠️⚠️ **这个标志是「搬家什么都不搬」那个 bug 的修复。**
    ///
    /// 起因：`PersonaStore.importBackup` 换完通讯录会调 `broadcastSwitch(to:)`，
    /// 而这时候我们（ChatStore）已经被恢复过了 —— `byContact` 里是**新搬进来的**，
    /// 但 `currentID` 还停在**这台旧机器上的**那个人。于是 `switchTo` 里那一句
    /// `byContact[currentID] = messages` 把旧会话写了回去，最后整个字典落盘的是
    /// 旧数据 —— 用户看到的就是「聊天记录一条都没搬过来」。
    ///
    /// 修法：搬家的路上只允许**读**，绝不允许 `stash()` 往字典里**写**。
    private var loading = false

    /// 切到某个联系人的对话。传 nil 就是「还没选定人」。
    func switchTo(_ id: UUID?) {
        stash()
        currentID = id
        if let id {
            messages = byContact[id] ?? []
        } else {
            messages = []
        }
        save()
    }

    /// 把某个联系人的对话整个删掉（删联系人时用）。
    func forget(_ id: UUID) {
        byContact[id] = nil
        if currentID == id {
            messages = []
        }
        save()
    }

    /// 老版本只有一个对话，存在 `aevis-messages.json` 里 ——
    /// 搬成这个联系人的记录。**不能丢。**
    ///
    /// 只有 `PersonaStore` 知道该认到谁名下，所以由它来调这个。
    func adoptLegacyMessages(for id: UUID) {
        guard byContact[id]?.isEmpty ?? true else { return }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let old = try? JSONDecoder().decode([ChatMessage].self, from: data),
              !old.isEmpty else { return }
        byContact[id] = old
        if currentID == id {
            messages = old
        }
        save()
    }

    // MARK: - 读写

    /// 有话要说的观察者（见 `addAppendListener`）。
    private var appendListeners: [(ChatMessage, UUID?) -> Void] = []

    /// 订阅「有新消息落进某个会话」。
    ///
    /// 谁在用：
    ///  · 生态第二期的**配对通道**（`PairChatBridge`）—— 把手机上这段聊天同步给电脑那块屏；
    ///  · **自动同步到网盘**（`AutoSync`）—— 每说一句就往网盘推一次。
    /// 挂在 `append` 里而不是各个调用点，理由跟 `track()` 一样：调用点有十几处，
    /// 漏一个就是"电脑上少一条"、而且**只在特定路径下少**，那种 bug 极难查。
    ///
    /// 🔴🔴 **这里必须是"可以挂多个"的**（2026-10-03 改）。
    ///    原来它是一个赋值位：`var onAppended: ((ChatMessage, UUID?) -> Void)?`，
    ///    第二个使用者 `=` 上去会把第一个**悄悄顶掉**：
    ///      · `PairChatBridge.start()` 先挂，`AutoSync.start()` 后挂 ⇒ 电脑端从此收不到消息；
    ///      · 反过来 ⇒ 网盘一直不更新。
    ///    两种都**完全不报错**，只是那个功能"永远不响"。
    ///    ⇒ 观察者表：只能加、不能替。以后再加使用者直接 `addAppendListener` 就行。
    ///
    /// ⚠️ 流式期间改字（`replaceLast` / `finishStreamingLine`）**不走这里** ——
    ///    那些增量由 `PairChatBridge` 自己以 `delta` 推给电脑。
    func addAppendListener(_ block: @escaping (ChatMessage, UUID?) -> Void) {
        appendListeners.append(block)
    }

    private func notifyAppended(_ message: ChatMessage, _ owner: UUID?) {
        for block in appendListeners {
            block(message, owner)
        }
    }

    func append(_ message: ChatMessage) {
        guard !isRepeat(message) else { return }
        messages.append(message)
        track(message)
        save()
        notifyAppended(message, currentID)
    }

    // MARK: - 转账 / 红包（假钱包）

    /// 记一条转账。**故意不走 `isRepeat`** ——
    /// 连着转两笔一模一样的金额（比如给两次 5.20）是正当行为，
    /// 被"防重复"吃掉的话用户只会看到"转了但聊天里没有"。
    @discardableResult
    func appendTransfer(_ transfer: ChatMessage.Transfer) -> UUID {
        let message = ChatMessage(role: .user,
                                  text: ChatMessage.transferLine(transfer, mine: true),
                                  kind: .transfer,
                                  transfer: transfer)
        messages.append(message)
        track(message)
        save()
        return message.id
    }

    /// 对面收下了 → 气泡上那个「待收款」变成「已收款」。
    func markTransferAccepted(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].transfer?.accepted = true
        save()
    }

    /// ⭐ #23（2026-09-30）：对面没肯收，钱退回 → 气泡标「已退回」。
    func markTransferDeclined(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].transfer?.declined = true
        save()
    }

    /// 她发给我一条转账 / 红包（她也有钱包）。
    ///
    /// ## ⚠️ 这个方法以前是**纯死代码**（2026-10-01 才发现）
    /// 「她给我打钱」那条路从来没接通：没人调它，`WalletStore.receive` 也没人调。
    /// 现在由 `WalletTools` 里的 `wallet_give_money` 真正调起来。
    ///
    /// ## ⚠️ 门槛不能用 `canReceiveProactive`
    /// 老代码在这里 `guard canReceiveProactive else { return nil }` ——
    /// 但她是在**回复你的过程中**决定给你转钱的，那一刻最后一条正是
    /// **空着的 assistant 占位**（她的话还在流式往外吐），一挡就全没了：
    /// 表现是「余额动了、聊天里什么都没有」，比不做还糟。
    ///
    /// 所以改成：**插到那个空占位前面**。她的话接着往后流、气泡在上面 ——
    /// 正好就是微信里「先发个红包、再补一句话」的顺序。
    /// `replaceLast(with:)` 认的是列表**最后一条**，插在前面不影响它在改谁。
    @discardableResult
    func appendIncomingTransfer(_ transfer: ChatMessage.Transfer) -> UUID? {
        let message = ChatMessage(role: .assistant,
                                  text: ChatMessage.transferLine(transfer, mine: false),
                                  kind: .transfer,
                                  transfer: transfer)
        let isStreamingPlaceholder = messages.last?.role == .assistant
            && messages.last?.text.isEmpty == true
        messages.insert(message, at: isStreamingPlaceholder ? messages.count - 1 : messages.count)
        track(message)
        save()
        return message.id
    }

    /// 把这条聊天记进黑匣子（用户 2026-09-26 要求：「聊天记录也要进日志」）。
    ///
    /// ⚠️ 两块内容**刻意只记类型、不记内容**：
    /// 图片记「［图片］」、其它附件记类型名 —— 日志是加密的，但也没必要多存一份图。
    /// 文本按 200 字截断（见 `BlackBox.chat`），免得一条长文把现场挤掉。
    ///
    /// 放在 `append` 里而不是各个调用点：**调用点有十几处**，
    /// 漏一个就永远查不到"她在说这句的时候崩了"。
    private func track(_ message: ChatMessage) {
        let who = message.role == .user ? "我" : "TA"
        if message.imageData != nil {
            BlackBox.chat(who, "［图片］")
            return
        }
        BlackBox.chat(who, message.text)
    }

    /// 要不要把这条丢掉。
    ///
    /// 规则分两种，因为两种重复的成因不一样：
    /// - **她的话**（assistant）：不管隔多久，同一句连着来两条就只留一条 ——
    ///   那是流式定稿的回声，不是她真想重复。
    /// - **自己的话**（user）：只有**一秒半之内**完全一样才算手滑重复发送；
    ///   隔了一会再发一遍同样的话，那是真的要发，不能替他删掉。
    private func isRepeat(_ message: ChatMessage) -> Bool {
        // 图片消息不参与去重：两张长得一样的图也得各显示一张
        guard message.imageData == nil else { return false }
        guard let last = messages.last(where: { !$0.text.isEmpty }) else { return false }
        guard last.imageData == nil, last.role == message.role else { return false }
        guard Self.isSameLine(last.text, message.text) else { return false }

        if message.role == .assistant { return true }
        return message.date.timeIntervalSince(last.date) < 1.5
    }

    /// 这两段字算不算「同一句」。
    ///
    /// 用户的原话：「检查一下你发的和他发的两段字是不是一样的，
    /// 或者加了个符号之类的 —— 一样的就删掉其中一个。」
    ///
    /// 比较前先把两边都洗成**只留字**（去掉空白、标点、表情、markdown 星号），
    /// 所以「你好」「你好。」「**你好**」「你好！ 」在它眼里是同一条。
    ///
    /// 只有一个字的（「嗯」「哦」）不合并 —— 连着说两遍本来就是正常的说话方式。
    static func isSameLine(_ left: String, _ right: String) -> Bool {
        let a = reduced(left)
        let b = reduced(right)
        guard a.count >= 2, b.count >= 2 else { return false }
        return a == b
    }

    /// 只留 ASCII 字母数字和汉字，其余（标点、空白、emoji、星号）全丢掉。
    ///
    /// ⚠️ 这里**故意不用 `CharacterSet.alphanumerics`** —— 它是 Unicode 语义的，
    /// 而且项目里已经因为它踩过一次坑（拼 URL 时中文一个字符都没被编码）。
    /// 手写范围反而更清楚：要留下什么，一眼就能看懂。
    ///
    /// 按「字符」而不是「码点」过滤：一个 emoji 往往由好几个码点拼成，
    /// 按码点筛会把它拆成半截乱码。
    private static func reduced(_ text: String) -> String {
        let kept = text.filter { character in
            let scalars = character.unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first else { return false }
            let value = scalar.value
            return (value >= 0x30 && value <= 0x39)     // 0-9
                || (value >= 0x41 && value <= 0x5A)     // A-Z
                || (value >= 0x61 && value <= 0x7A)     // a-z
                || (value >= 0x4E00 && value <= 0x9FFF) // 汉字
        }
        return kept.lowercased()
    }

    /// 往**指定联系人**的对话里放一条消息。
    ///
    /// 为什么需要它：通话可以从任何地方拉起来（联系人页、发现页、`aevis://call`），
    /// 那一刻 `currentID` 不一定是"正在通话的这个人"。
    /// 早先通话直接用 `append`，后果有两个，一个比一个隐蔽：
    /// 消息落进别人的会话（用户在正确的人那里看不到），
    /// 以及 `currentID` 为 nil 时 `stash()` 什么也不写 —— **消息连盘都不落**，重启就没了。
    func append(_ message: ChatMessage, for id: UUID?) {
        guard let id else {
            append(message)
            return
        }
        if currentID == id {
            messages.append(message)
        } else {
            byContact[id, default: []].append(message)
        }
        track(message)
        save()
        notifyAppended(message, id)
    }

    /// 现在能不能接收她主动发来的消息。
    ///
    /// **正在等她回复的时候不行** —— 最后一条是空的 assistant 占位，
    /// 这时候插一条会把她正在流式吐出来的半句话顶乱。
    var canReceiveProactive: Bool {
        guard let last = messages.last else { return true }
        return !(last.role == .assistant && last.text.isEmpty)
    }

    /// 她主动发来的一句话（朋友圈那边触发 / 定时通知之外的那种）。
    /// 返回是否真的放下了。
    @discardableResult
    func appendProactive(_ text: String) -> Bool {
        appendProactive(text, for: nil)
    }

    /// 同上，但指定**落到哪个会话**。
    ///
    /// ⚠️ 为什么要这个重载：通知是在**排程那一刻**就写好"说给谁听"的，
    ///    而用户可能在通知弹出来之后切到了另一个联系人。
    ///    `owner` 为 nil 时才落到当前会话。
    @discardableResult
    func appendProactive(_ text: String, for owner: UUID?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // 落到"别人"的会话时，只能看那个会话自己的最后一条 ——
        // 拿当前会话的 `messages` 判断会把刚说的话当成重复。
        let target = owner ?? currentID
        let list: [ChatMessage]
        if let target, target != currentID {
            list = byContact[target] ?? []
        } else {
            list = messages
        }

        // 正在等她回复的时候不行 —— 最后一条是空的 assistant 占位，
        // 这时候插一条会把她正在流式吐出来的半句话顶乱。
        if let last = list.last, last.role == .assistant, last.text.isEmpty {
            return false
        }
        if let last = list.last(where: { !$0.text.isEmpty }),
           last.role == .assistant,
           Self.isSameLine(last.text, trimmed) {
            return false
        }

        append(ChatMessage(role: .assistant, text: trimmed), for: target)
        return true
    }

    /// 流式回复期间只改内存，不每次落盘。
    ///
    /// ⚠️ **必须 trim 首尾空白** —— 2026-10-01 修的，症状是「她每句话开头多一个空格」：
    ///
    /// 模型经常会吐成 `" 我这 儿还看不到日期呢宝宝。"`（行首一个空格）。
    /// 这个半句先经这里上屏（带空格），等换行真到了，`finishStreamingLine`
    /// 会 trim 一次再定稿 —— 看着应该能盖掉。但**盖不掉**，因为
    /// `isSameLine` 比较前会把两边的空白/标点全洗掉（见它自己的注释），
    /// 于是带空格的那版和定稿版被判成"同一条"→ 走"跳过定稿"那条分支 →
    /// **留在屏幕上的还是带空格的那版**。
    ///
    /// 治本就在这一行：这里显示的本来就只是"还没定稿的半句"，
    /// 首尾空白没有任何意义，trim 掉之后两条路径就完全一致了。
    func replaceLast(with text: String) {
        guard let index = messages.indices.last else { return }
        messages[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 流式结束后落盘。
    func commit() {
        save()
    }

    /// 流式过程中「这一条说完了」：把它定稿，再开一条新的空占位接着收。
    ///
    /// 她在提示词里被要求「像真人发消息、短句」—— 所以**她换行就等于换一条消息**，
    /// 这样看起来才是一条一条发出来的，而不是一大段。
    func finishStreamingLine(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // ⚠️ **这一行是「她每句话都说两遍」的真凶。**
        //
        // 她正在吐的那半句是靠 `replaceLast` **实时写在最后一条上**的
        // （见 ChatView.flushLines）。所以当模型接着吐出一个换行、这一行被
        // 正式定稿时，屏幕上那条**已经是同一句话了** —— 再追加一条，
        // 就变成「B」显示两次。
        //
        // 触发条件很常见：模型先吐「B」，隔一会才吐「\n」。
        // 前面那句"结束时不要再定稿一次"只挡住了整段结束的那一刻，
        // 挡不住**每一行**的这一下。用户的原话是
        // 「检查一下你发的和我发的是不是一样的，加了个符号之类的，一样的删掉一个」。
        if let index = messages.indices.last,
           messages[index].role == .assistant,
           Self.isSameLine(messages[index].text, trimmed) {
            // ⚠️ **顺手把最后一条换成定稿版**（2026-10-01 加）。
            // 屏幕上那半句可能带着首尾空白（模型爱在行首留空格），
            // 而 `isSameLine` 洗掉空白之后照样判成"同一条"。
            // 只补空占位、不覆盖的话，带空格的那版就永久留在聊天气泡里了。
            // 覆盖成 `trimmed` 是安全的 —— 两边去空白后本来就相等。
            messages[index].text = trimmed
            // 定稿的动作跳过，但**空占位必须补上** —— 不补的话下一条
            // 半句会直接覆盖掉刚定稿的这一条。
            messages.append(ChatMessage(role: .assistant, text: ""))
            return
        }

        if let index = messages.indices.last,
           messages[index].role == .assistant,
           messages[index].text.isEmpty {
            messages[index].text = trimmed
        } else {
            messages.append(ChatMessage(role: .assistant, text: trimmed))
        }
        // 再开一条空占位，接着收下一行
        messages.append(ChatMessage(role: .assistant, text: ""))
    }

    /// 出错或被打断时，把没内容的占位消息扔掉。
    func removeLastIfEmpty() {
        if let last = messages.last, last.text.isEmpty {
            messages.removeLast()
            save()
        }
    }

    /// 清空**当前联系人**的对话。别的联系人不受影响。
    func clear() {
        messages.removeAll()
        save()
    }

    /// 某个联系人有没有聊过（会话列表要显示预览）。
    func messageCount(for id: UUID) -> Int {
        if currentID == id { return messages.count }
        return byContact[id]?.count ?? 0
    }

    /// 某个人最后一条有内容的消息（会话列表的预览行）。
    func lastMessage(for id: UUID) -> ChatMessage? {
        let list = currentID == id ? messages : (byContact[id] ?? [])
        return list.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var byContact: [String: [ChatMessage]] = [:]
    }

    /// 把当前这份写回字典。任何落盘之前都要先做一次。
    ///
    /// ⚠️ `loading` 为真时**什么都不写** —— 那会拿这台旧机器的会话
    /// 覆盖掉刚搬进来的数据。见 `loading` 的注释。
    private func stash() {
        guard !loading else { return }
        if let currentID { byContact[currentID] = messages }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间同样禁写：紧接着的 `broadcastSwitch` 会先切人，
        //    那一句 `stash()` 会拿 `messages`（还是空的）盖掉刚读出来的记录。
        loading = true
        defer { loading = false }
        byContact = archived.byContact.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        // ⚠️ 顺手洗一遍**已经存下来**的首尾空白（2026-10-01）。
        //
        // 0.0.92 之前有个 bug：模型的半句带着行首空格先上屏，定稿时因为
        // `isSameLine` 洗掉空白后判成"同一条"而跳过，于是那条带空格的消息
        // **被写进了历史**。上面那两处修的是"以后不再产生"，
        // 这里修的是"已经躺在记录里的那些" —— 不然用户升级之后
        // 照样能看到「 我这 儿还看不到日期呢宝宝。」这种开头顶一格的消息。
        //
        // ⚠️ **先收集、再赋值** —— 不能边遍历 `byContact` 边写它，
        // Swift 的独占内存访问会当场报 "overlapping accesses"。
        var cleaned: [UUID: [ChatMessage]] = [:]
        for (id, list) in byContact {
            cleaned[id] = list.map { message in
                var copy = message
                copy.text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
        }
        byContact = cleaned
        // 注意：这里**不**去读老文件 —— 老的对话该认到哪个联系人名下，
        // 只有 PersonaStore 知道，等它调 adoptLegacyMessages(for:) 再说。
    }

    private func save() {
        // 搬家 / 读档的路上不落盘 —— 见 `loading` 的注释。
        guard !loading else { return }
        stash()
        writeArchive()
    }

    /// 把 `byContact` 原样写进文件，**不经过 `stash()`**。
    /// 只在 `save()` 和导入里用 —— 这两处字典已经是最终状态了。
    private func writeArchive() {
        let flat = byContact.reduce(into: [String: [ChatMessage]]()) { result, item in
            result[item.key.uuidString] = item.value
        }
        guard let data = try? JSONEncoder().encode(Archive(byContact: flat)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 备份与搬家

extension ChatStore: BackupableStore {
    var backupName: String { "chats" }

    /// 导出**所有人**的对话。按联系人的 uuidString 存，恢复时才能对上号。
    func exportBackup() throws -> Data {
        stash()
        let flat = byContact.reduce(into: [String: [ChatMessage]]()) { result, item in
            result[item.key.uuidString] = item.value
        }
        return try JSONEncoder().encode(Archive(byContact: flat))
    }

    func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 整个导入过程禁掉 `stash()` / `save()`：中途 `setOwner` 会先切人，
        //    那一下要是允许写回，刚搬进来的数据当场就被旧会话顶掉了。
        loading = true
        defer { loading = false }
        byContact = archive.byContact.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        // 当前看着的那个人也得跟着换一份，否则界面上还是旧内容
        messages = currentID.flatMap { byContact[$0] } ?? []
        // 字典已经在内存里了，这里**一定要真落盘**（上面的 loading 还没解除）
        writeArchive()
    }
}
