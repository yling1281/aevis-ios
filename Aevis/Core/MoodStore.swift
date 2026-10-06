import Foundation

/// ta的「心情 + 心里话」。
///
/// ta在回复的最后一行会自己写一个标记，例如：
///     〔心情：想你｜心里话：你今天回消息比平时慢，我数了下时间〕
/// 这里把它剥离出来存下 —— 所以**用户永远看不到那个标记**，
/// 看到的是剥干净之后的正常回复。
///
/// ## 谁在用
/// - 聊天页（`ChatView.send`）：拿到ta整段回复后调 `consume(_:)` 剥标记 + 落库；
/// - ta的资料页：读 `current` 展示最近一次的心情；
/// - 系统提示词：把 `current` 喂回去，让ta"记得自己上次在想什么"。
///
/// ## 为什么不放进 `AppSettings`
/// 它是「ta的状态」，不是「用户的设置」—— 混在一起会让设置页的存档越滚越大，
/// 也不利于按联系人区分（将来想做成"每个人一套心情"时改这里就行）。
final class MoodStore: ObservableObject {

    static let shared = MoodStore()

    struct Mood: Codable, Equatable {
        var mood: String        // 两三个字，如「想你」
        var innerVoice: String  // 一句第一人称独白，≤30 字
        var updatedAt: Date
    }

    @Published private(set) var current: Mood?

    /// 持久化键。写法照 `AmbientContext`（UserDefaults + JSON 编码）。
    private static let key = "aevis.mood"

    private init() {
        load()
    }

    // MARK: - 对外

    /// 从ta的回复里剥离末尾标记并写入；返回**剥干净后**的文本。
    /// 没找到标记 ⇒ 原样返回，且**不改动** `current`。
    ///
    /// ⚠️ 只认**最后一行**：ta可能在正文里正常写到「心情」两个字，
    ///    那种情况不能被当成标记（否则会把ta的正文吃出个洞）。
    @discardableResult
    func consume(_ reply: String) -> String {
        let normalized = Self.normalize(reply)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return reply }

        // 只看最后一行
        let lastLine: String
        if let newline = trimmed.lastIndex(of: "\n") {
            lastLine = String(trimmed[trimmed.index(after: newline)...])
        } else {
            lastLine = trimmed
        }

        guard let parsed = Self.marker(in: lastLine) else { return reply }

        // 截断：mood ≤ 6 字，innerVoice ≤ 60 字
        let mood = String(parsed.mood.prefix(6))
        let innerVoice = String(parsed.innerVoice.prefix(60))
        // 两栏都空 ⇒ 这不是一个有效标记，按"没找到"处理
        guard !mood.isEmpty || !innerVoice.isEmpty else { return reply }

        let entry = Mood(mood: mood, innerVoice: innerVoice, updatedAt: Date())
        current = entry
        store(entry)

        // 剥掉标记之后剩下的正文；如果被剥没了就返回原文（别把整条回复吃没了）
        let clean = Self.strippingMarker(from: normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? reply : clean
    }

    /// 清掉当前心情（用户手动擦掉 / 换人）。
    func clear() {
        current = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    // MARK: - 解析（纯函数，不碰状态 —— 聊天流收尾时也用它）

    /// 只剥末尾标记、**不写入、不改 `current`**。
    ///
    /// 聊天流是逐字上屏的，标记在流式过程中就已经显示在最后一条气泡上了；
    /// 收尾时要把那一条也剥干净，就调它。返回剥掉标记后的文本
    /// （没找到标记时原样返回）。
    static func strippingMarker(from text: String) -> String {
        let normalized = normalize(text)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let lastLine: String
        let head: String
        if let newline = trimmed.lastIndex(of: "\n") {
            lastLine = String(trimmed[trimmed.index(after: newline)...])
            head = String(trimmed[...newline])   // 含那个换行，保留原有分句
        } else {
            lastLine = trimmed
            head = ""
        }

        guard let parsed = marker(in: lastLine) else { return text }
        let strippedLine = lastLine.replacingCharacters(in: parsed.range, with: "")
        return head + strippedLine
    }

    /// 统一换行，方便按「行」处理。
    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// 从**一行**里认出标记。
    ///
    /// 返回 (心情, 心里话, 标记在行内的区间)。认不出标记（或连标签都没有）⇒ nil。
    /// - 括号：`〔…〕` / `【…】` / `[…]` 都认（全角半角都行）
    /// - 分隔符：`｜` 或 `|`
    /// - 标签：`心情` / `心里话`，标签与冒号之间允许空格
    private static func marker(in line: String) -> (mood: String, innerVoice: String,
                                                    range: Range<String.Index>)? {
        let openers: Set<Character> = ["〔", "【", "["]
        let closers: Set<Character> = ["〕", "】", "]"]

        guard let openIndex = line.firstIndex(where: { openers.contains($0) }) else { return nil }

        // 取 openIndex 之后**最后一个**闭合符 —— 万一正文里还出现别的方括号，
        // 也能把整段标记一起圈进来。
        var closeIndex: String.Index?
        var cursor = line.index(after: openIndex)
        while cursor < line.endIndex {
            if closers.contains(line[cursor]) { closeIndex = cursor }
            cursor = line.index(after: cursor)
        }
        guard let close = closeIndex, close > openIndex else { return nil }

        let range = openIndex..<line.index(after: close)
        let inner = String(line[line.index(after: openIndex)..<close])

        let moodRange = inner.range(of: "心情")
        let voiceRange = inner.range(of: "心里话")
        guard moodRange != nil || voiceRange != nil else { return nil }

        var mood = ""
        var innerVoice = ""
        if let voiceRange {
            innerVoice = cleanValue(String(inner[voiceRange.upperBound...]))
            if let moodRange, moodRange.lowerBound < voiceRange.lowerBound {
                mood = cleanValue(String(inner[moodRange.upperBound..<voiceRange.lowerBound]))
            }
        } else if let moodRange {
            mood = cleanValue(String(inner[moodRange.upperBound...]))
        }
        return (mood, innerVoice, range)
    }

    /// 把「标签后面的那一段」清成纯内容：
    /// 掐掉紧跟的冒号（全角/半角）与空白，再掐掉尾部的分隔符 / 逗号 / 空白。
    private static func cleanValue(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, first == "：" || first == ":" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        let tail: Set<Character> = ["｜", "|", "，", ",", " ", "　"]
        while let last = text.last, tail.contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 存

    private func store(_ entry: Mood) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode(Mood.self, from: data) else { return }
        current = saved
    }
}

// MARK: - 备份与搬家
//
// ⚠️ 这个 conformance **是 `BackupService.swift` 点名要的**（见那边 `stores()` 上面那段）：
//    它把 `label("mood") = "ta的心情"` 已经备好了，就等这里补上三件套。
//    少了它，`MoodStore.shared` 一旦被加进 `stores()` 数组，那边**直接编不过**。
extension MoodStore: BackupableStore {

    var backupName: String { "mood" }

    /// 备份包里的形状 —— 单独包一层，免得直接编码 `Mood?` 时踩到「顶层 null」那点边角语义。
    struct Archive: Codable {
        var current: Mood?
    }

    func exportBackup() throws -> Data {
        try JSONEncoder().encode(Archive(current: current))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        current = archived.current
        if let saved = archived.current {
            store(saved)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
