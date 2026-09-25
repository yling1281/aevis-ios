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

    func append(_ message: ChatMessage) {
        guard !isRepeat(message) else { return }
        messages.append(message)
        save()
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
        save()
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canReceiveProactive else { return false }
        // 她主动来的这句跟上一句一模一样就别再发一遍
        if let last = messages.last(where: { !$0.text.isEmpty }),
           last.role == .assistant,
           Self.isSameLine(last.text, trimmed) {
            return false
        }
        messages.append(ChatMessage(role: .assistant, text: trimmed))
        save()
        return true
    }

    /// 流式回复期间只改内存，不每次落盘。
    func replaceLast(with text: String) {
        guard let index = messages.indices.last else { return }
        messages[index].text = text
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
    private func stash() {
        if let currentID { byContact[currentID] = messages }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        byContact = archived.byContact.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        // 注意：这里**不**去读老文件 —— 老的对话该认到哪个联系人名下，
        // 只有 PersonaStore 知道，等它调 adoptLegacyMessages(for:) 再说。
    }

    private func save() {
        stash()
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
        byContact = archive.byContact.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        // 当前看着的那个人也得跟着换一份，否则界面上还是旧内容
        messages = currentID.flatMap { byContact[$0] } ?? []
        save()
    }
}
