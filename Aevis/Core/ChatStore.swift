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
        messages.append(message)
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
