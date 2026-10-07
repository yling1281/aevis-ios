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
/// 它是「ta的状态」，不是「用户的设置」—— 混在一起会让设置页的存档越滚越大。
///
/// ## ⭐ 2026-10：**按联系人分开存**
/// 老板拍板「每个人都是独立的」—— A 的「想你」不该出现在 B 的资料页。
/// 每个人的心情按 `owner`（= 联系人 id）分开存，切人时 `setOwner` 换一份。
/// 老版本那枚单人键 `aevis.mood` 会在**第一次认人**时认给那个人（见 `setOwner`）。
///
/// ⚠️ **异步通道要传 owner**：`ProactiveService` 的主动消息是**按 owner 排程**的，
///    回来时用户可能已经切到别人 —— 那条 `consume(_:owner:)` 必须带上
///    「这条是说给谁听的」，否则会把 B 的心情写到当前打开的 A 头上。
final class MoodStore: ObservableObject {

    static let shared = MoodStore()

    struct Mood: Codable, Equatable {
        var mood: String        // 两三个字，如「想你」
        var innerVoice: String  // 一句第一人称独白，≤30 字
        var updatedAt: Date
    }

    @Published private(set) var current: Mood?

    /// 每个人的心情，**按联系人分开存**（不然换了人还看着上一个人的心情）。
    private var byOwner: [UUID: Mood] = [:]
    /// 现在这份属于谁。
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**（同 `TodoStore.loading`）。
    private var loading = false
    /// 新格式存档读到没有 / 老存档认过没有 —— 老键只认一次。
    private var loadedArchive = false
    private var adoptedLegacy = false

    /// 持久化键（按联系人那份）。写法照 `AmbientContext`（UserDefaults + JSON 编码）。
    private static let byContactKey = "aevis.mood.by-contact"
    /// 老版本（单人）那枚键，**只用来做一次性迁移**。
    private static let legacyKey = "aevis.mood"

    /// 存档 / 备份共用的结构。
    /// - `byOwner`：新结构，按联系人。
    /// - `current`：**只在读老备份时非空**（老版本只有单人那一份）。
    ///   Optional + 默认 nil ⇒ 写盘时被 `encodeIfPresent` 省略，新备份里不会多出这一段。
    private struct Archive: Codable {
        /// 新结构，按联系人。🔴 **必须可选项** —— Swift 合成的 `Decodable` 不吃
        /// 属性默认值，非可选缺键会直接抛 `keyNotFound`（老单人备份整条解不出）。
        /// 老备份没有这个键 ⇒ nil，`current` 才有值。
        var byOwner: [String: Mood]? = nil
        var current: Mood? = nil
    }

    private init() {
        load()
    }

    // MARK: - 切人

    /// 切到某个联系人。`PersonaStore` 切人时来调它。
    func setOwner(_ id: UUID?) {
        stash()
        owner = id

        guard let id else {
            current = nil
            return
        }

        // 老版本只有一份、没分人 —— 认给**第一个进来的人**。只在还没读到新档时认一次。
        if !loadedArchive, !adoptedLegacy {
            adoptedLegacy = true
            if byOwner[id] == nil, let legacy = Self.readLegacy() {
                byOwner[id] = legacy
                writeArchive()
            }
        }

        current = byOwner[id]
    }

    /// 把某个联系人的心情整个删掉（删联系人时用）。
    func forget(_ id: UUID) {
        byOwner[id] = nil
        if owner == id { current = nil }
        writeArchive()
    }

    // MARK: - 对外

    /// 从ta的回复里剥离末尾标记并写入；返回**剥干净后**的文本。
    /// 没找到标记 ⇒ 原样返回，且**不改动** `current`。
    ///
    /// - Parameter owner: 这条回复**是说给谁听的**。
    ///   · 聊天页 / 通话这些「就在当前这个人身上」的路径可以不给（默认 = 当前联系人）；
    ///   · 异步 / 按 owner 排程的通道（主动消息 `ProactiveService`、QQ、配对桥）
    ///     **必须给**，否则会把那个人的心情写到当前打开的人头上。
    ///
    /// ⚠️ 只认**最后一行**：ta可能在正文里正常写到「心情」两个字，
    ///    那种情况不能被当成标记（否则会把ta的正文吃出个洞）。
    @discardableResult
    func consume(_ reply: String, owner: UUID? = nil) -> String {
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
        let resolved = owner ?? self.owner
        if let resolved {
            byOwner[resolved] = entry
            if resolved == self.owner { current = entry }
            writeArchive()
        } else {
            // 极端：还没认人。别丢，先落内存 + 老键兜底。
            current = entry
            Self.writeLegacy(entry)
        }

        // 剥掉标记之后剩下的正文；如果被剥没了就返回原文（别把整条回复吃没了）
        let clean = Self.strippingMarker(from: normalized)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? reply : clean
    }

    /// 清掉**当前联系人**的心情（ta的资料页里用户手动擦掉）。
    ///
    /// ⚠️ 切人**不走这里** —— 换人由 `setOwner` 换一份；旧写法在切人时调
    ///    `clear()` 会把刚载入的新主人的心情当场擦掉（已改）。
    func clear() {
        current = nil
        if let owner { byOwner[owner] = nil }
        writeArchive()
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
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

    /// 把当前这份写回字典。
    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        byOwner[owner] = current
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.byContactKey),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间禁写，理由同 `TodoStore.load()`：紧接着的 `setOwner` 会先
        //    `stash()`，用旧机器的那份盖掉刚读进来的。
        loading = true
        defer { loading = false }
        byOwner = (archived.byOwner ?? [:]).reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        loadedArchive = true
    }

    /// 把 `byOwner` 原样落盘，**不经过 `stash()`**。导入 / 迁移时用。
    private func writeArchive() {
        guard !byOwner.isEmpty else { return }
        let flat = byOwner.reduce(into: [String: Mood]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        guard let data = try? JSONEncoder().encode(Archive(byOwner: flat)) else { return }
        UserDefaults.standard.set(data, forKey: Self.byContactKey)
    }

    private static func readLegacy() -> Mood? {
        guard let data = UserDefaults.standard.data(forKey: legacyKey) else { return nil }
        return try? JSONDecoder().decode(Mood.self, from: data)
    }

    private static func writeLegacy(_ entry: Mood) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: legacyKey)
    }
}

// MARK: - 备份与搬家
//
// ⚠️ 这个 conformance **是 `BackupService.swift` 点名要的**（见那边 `stores()` 上面那段）：
//    它把 `label("mood") = "ta的心情"` 已经备好了，就等这里补上三件套。
//    少了它，`MoodStore.shared` 一旦被加进 `stores()` 数组，那边**直接编不过**。
extension MoodStore: BackupableStore {

    var backupName: String { "mood" }

    /// 导出**所有人的**心情 —— 搬家要搬的是全部，不只当前这个。
    func exportBackup() throws -> Data {
        stash()
        let flat = byOwner.reduce(into: [String: Mood]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        return try JSONEncoder().encode(Archive(byOwner: flat))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入全程禁写：中途 `PersonaStore.broadcastSwitch` 会调 `setOwner`。
        loading = true
        defer { loading = false }
        if let imported = archived.byOwner, !imported.isEmpty {
            byOwner = imported.reduce(into: [:]) { result, pair in
                guard let id = UUID(uuidString: pair.key) else { return }
                result[id] = pair.value
            }
        } else if let old = archived.current {
            // 老备份（单人）→ 认到现在的 active（`PersonaStore` 已先导完通讯录）。
            let fallback = PersonaStore.shared.activeID ?? PersonaStore.shared.contacts.first?.id
            if let fallback { byOwner[fallback] = old }
        }
        current = owner.flatMap { byOwner[$0] }
        writeArchive()
    }
}
