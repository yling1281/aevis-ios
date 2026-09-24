import Foundation

/// 对话记录与跨会话记忆。全部存在这台设备上。
final class ChatStore: ObservableObject {
    static let shared = ChatStore()

    @Published private(set) var messages: [ChatMessage] = []

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-messages.json")
        load()
    }

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

    /// 出错或被打断时，把没内容的占位消息扔掉。
    func removeLastIfEmpty() {
        if let last = messages.last, last.text.isEmpty {
            messages.removeLast()
            save()
        }
    }

    func clear() {
        messages.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return
        }
        messages = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
