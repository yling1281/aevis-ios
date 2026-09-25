import Foundation

/// 一条长期记忆。
struct MemoryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case fact
        case preference
        case event
        case promise

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fact: return "事实"
            case .preference: return "喜好"
            case .event: return "经历"
            case .promise: return "约定"
            }
        }

        var symbol: String {
            switch self {
            case .fact: return "person.text.rectangle"
            case .preference: return "heart"
            case .event: return "calendar"
            case .promise: return "hand.raised"
            }
        }
    }

    var id: String = UUID().uuidString
    var kind: Kind = .fact
    var text: String = ""
    var createdAt: Date = Date()
    /// 钉住的记忆永远优先带上，也不会被自动整理掉。
    var pinned: Bool = false
}

/// 长期记忆库。
///
/// 三件事：
/// 1. **自动提炼** —— 聊够一段就让她把「值得长期记住」的挑出来存下；
/// 2. **手动管理** —— 能加、能改、能删、能钉；
/// 3. **备份** —— 导出成 JSON，也留本地快照，能一键恢复。
///
/// 全部只存在这台手机上（备份文件在 App 自己的目录里）。
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// 当前联系人的长期记忆（老入口，保持不变）。
    @Published private(set) var items: [MemoryItem] = []

    /// 每个人的记忆分开放 —— 不然换了人之后她还会「记得」上一个人的事，
    /// 那比不记得更糟。
    private var byOwner: [UUID: [MemoryItem]] = [:]
    private var owner: UUID?

    /// 上次提炼是在消息数到多少时做的。避免每说一句话就去调一次模型。
    /// **按联系人分开记** —— 否则换了人之后，提炼进度会被上一个人的对话条数带偏。
    @Published var extractedUpTo: Int {
        didSet { UserDefaults.standard.set(extractedUpTo, forKey: currentExtractedKey) }
    }

    @Published private(set) var working = false
    /// 最近一次操作的结果，界面上显示一行。外面也能写，方便直接从界面报错。
    @Published var statusLine: String?

    private static let extractedKey = "aevis.memoryExtractedUpTo"
    private let fileURL: URL
    private let legacyFileURL: URL
    private let backupDirectory: URL
    /// 新格式的存档读到了没有 —— 没读到才有必要去认老的那一份。
    private var loadedArchive = false
    /// 老存档只认一次，别每切一次人就搬一遍。
    private var adoptedLegacy = false

    private var currentExtractedKey: String {
        guard let owner else { return Self.extractedKey }
        return Self.extractedKey + "." + owner.uuidString
    }

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-memory-by-contact.json")
        legacyFileURL = base.appendingPathComponent("aevis-memory.json")

        backupDirectory = base.appendingPathComponent("AevisMemoryBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        // 初始化时赋值**不会**触发 didSet，所以这里写 0 不会把老键上的进度冲掉。
        extractedUpTo = 0
        load()
    }

    // MARK: - 切人

    /// 切到某个联系人。`PersonaStore` 切人的时候会来调它。
    func setOwner(_ id: UUID?) {
        stash()
        owner = id

        guard let id else {
            items = []
            return
        }

        // 老版本只有一份记忆、没分人 —— 认给第一个进来的人。
        // 只在「没有新格式存档」并且「还没认过」的时候做一次。
        if !loadedArchive, !adoptedLegacy {
            adoptedLegacy = true
            if let legacy = readLegacy(), !legacy.isEmpty {
                byOwner[id] = legacy
            }
        }

        items = byOwner[id] ?? []
        extractedUpTo = UserDefaults.standard.integer(forKey: currentExtractedKey)
    }

    /// 把某个联系人的记忆整个删掉（删联系人时用）。
    func forget(_ id: UUID) {
        byOwner[id] = nil
        if owner == id { items = [] }
        UserDefaults.standard.removeObject(forKey: Self.extractedKey + "." + id.uuidString)
        save()
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        byOwner = archived.byOwner.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        loadedArchive = true
    }

    private func readLegacy() -> [MemoryItem]? {
        guard let data = try? Data(contentsOf: legacyFileURL) else { return nil }
        return try? JSONDecoder().decode([MemoryItem].self, from: data)
    }

    /// 把当前这份写回字典。任何落盘之前都要先做一次。
    private func stash() {
        if let owner { byOwner[owner] = items }
    }

    private func save() {
        stash()
        // 空字典不落盘 —— 否则第一次启动还没认人，就会写一份空存档，
        // 下次就再也认不到老的那份记忆了。
        guard !byOwner.isEmpty else { return }
        let flat = byOwner.reduce(into: [String: [MemoryItem]]()) { result, item in
            result[item.key.uuidString] = item.value
        }
        guard let data = try? JSONEncoder().encode(Archive(byOwner: flat)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private struct Archive: Codable {
        var byOwner: [String: [MemoryItem]] = [:]
    }

    // MARK: - 增删改

    func add(_ text: String, kind: MemoryItem.Kind = .fact, pinned: Bool = false, quiet: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.insert(MemoryItem(kind: kind, text: trimmed, pinned: pinned), at: 0)
        save()
        if !quiet { statusLine = "记住了一条。" }
    }

    func update(_ item: MemoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    func remove(_ item: MemoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func togglePin(_ item: MemoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinned.toggle()
        save()
    }

    func clear() {
        items.removeAll()
        save()
        statusLine = "记忆库已清空。"
    }

    // MARK: - 注入

    /// 给模型看的那一段。钉住的排前面，总量有上限 ——
    /// 记忆太多会挤掉真正的对话，反而让她变笨。
    func injectedLines(limit: Int = 60, characterBudget: Int = 2400) -> [String] {
        guard !items.isEmpty else { return [] }

        let sorted = items.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned }
            return left.createdAt > right.createdAt
        }

        var lines: [String] = []
        var used = 0
        for item in sorted.prefix(limit) {
            let line = "- [\(item.kind.label)] \(item.text)"
            if used + line.count > characterBudget { break }
            lines.append(line)
            used += line.count
        }
        return lines
    }

    // MARK: - 自动提炼

    /// 聊得够多了就提炼一次。
    /// - Parameter messageCount: 当前对话总条数
    func extractIfNeeded(config: LLMConfig, messages: [ChatMessage], persona: Persona, force: Bool = false) async {
        guard !working else { return }
        guard config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

        let threshold = AppSettings.shared.memoryExtractEvery
        let pending = messages.count - extractedUpTo
        guard force || pending >= threshold else { return }

        // 只把最近这段给她看，不用把整段历史塞进去
        let window = messages.suffix(max(threshold, 12))
            .filter { !$0.text.isEmpty }
        guard window.count >= 4 else { return }

        working = true
        defer { working = false }

        let transcript = window.map { item in
            "\(item.role == .user ? "对方" : "我")：\(item.text)"
        }.joined(separator: "\n")

        let instruction = """
        从下面这段聊天里，挑出**值得长期记住**的信息。只挑这几类：
        事实（他是谁、住哪、做什么）、喜好（喜欢的讨厌的）、经历（发生过的事）、约定（说好要做的事）。
        不要挑：寒暄、情绪发泄、临时话题、你自己的想法。

        每条一行，格式必须是：`[类型] 内容`
        类型只能是 事实 / 喜好 / 经历 / 约定 里的一个。内容用第三人称写「对方」，一句话，不超过 30 字。
        没有值得记的就什么都不输出。最多 5 条。

        --- 聊天记录 ---
        \(transcript)
        """

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: "你是\(persona.name)，你在帮自己整理长期记忆。只输出要求的格式，不要解释。",
                history: [ChatMessage(role: .user, text: instruction)],
                memory: []
            ) {
                collected += piece
                if collected.count > 1500 { break }
            }
        } catch {
            statusLine = "提炼记忆失败：\(error.localizedDescription)"
            return
        }

        let parsed = Self.parse(collected)
        extractedUpTo = messages.count

        guard !parsed.isEmpty else {
            statusLine = "这一段没什么值得记的。"
            return
        }

        var added = 0
        for entry in parsed where !isDuplicate(entry.text) {
            items.insert(MemoryItem(kind: entry.kind, text: entry.text), at: 0)
            added += 1
        }
        if added > 0 { save() }
        statusLine = added == 0 ? "没有新东西要记。" : "记住了 \(added) 条。"
    }

    /// 太像的就不再存一遍。先按去标点的正文比，再看是否互相包含。
    private func isDuplicate(_ text: String) -> Bool {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return true }
        for item in items {
            let existing = Self.normalize(item.text)
            if existing == normalized { return true }
            if existing.count > 4, normalized.count > 4 {
                if existing.contains(normalized) || normalized.contains(existing) { return true }
            }
        }
        return false
    }

    private static func normalize(_ text: String) -> String {
        let keep = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.punctuationCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(keep))
    }

    /// 解析 `[事实] 内容` 这种行。模型偶尔会写歪，所以尽量宽容。
    private static func parse(_ raw: String) -> [(kind: MemoryItem.Kind, text: String)] {
        var result: [(MemoryItem.Kind, String)] = []
        for rawLine in raw.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            // 去掉行首的序号和列表符号
            while let first = line.first, first.isNumber || first == "-" || first == "*" || first == "." || first == " " {
                line.removeFirst()
            }
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let tag = String(line[line.index(after: line.startIndex)..<close])
            let body = String(line[line.index(after: close)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " :：-"))
            guard !body.isEmpty, body.count <= 60 else { continue }

            let kind: MemoryItem.Kind
            if tag.contains("喜好") || tag.contains("preference") {
                kind = .preference
            } else if tag.contains("经历") || tag.contains("event") {
                kind = .event
            } else if tag.contains("约定") || tag.contains("promise") {
                kind = .promise
            } else {
                kind = .fact
            }
            result.append((kind, body))
        }
        return result
    }

    // MARK: - 备份

    var isPlainEmpty: Bool { items.isEmpty }

    /// 导出成 JSON 数据，用于分享出去或存网盘。
    func exportData() -> Data? {
        let payload = BackupPayload(
            app: "Aevis",
            version: 1,
            exportedAt: Date(),
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    /// 导入一份备份。返回新增了多少条。已经有的会跳过。
    @discardableResult
    func importData(_ data: Data) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var incoming: [MemoryItem] = []
        if let payload = try? decoder.decode(BackupPayload.self, from: data) {
            incoming = payload.items
        } else if let plain = try? decoder.decode([MemoryItem].self, from: data) {
            incoming = plain
        } else {
            statusLine = "这个文件不是 Aevis 的记忆备份。"
            return 0
        }

        var added = 0
        for item in incoming {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isDuplicate(text) else { continue }
            items.append(MemoryItem(kind: item.kind, text: text, pinned: item.pinned))
            added += 1
        }
        if added > 0 { save() }
        statusLine = added == 0 ? "备份里没有新记忆。" : "从备份恢复了 \(added) 条。"
        return added
    }

    /// 存一份本地快照，返回文件名。
    @discardableResult
    func snapshot() -> String? {
        guard let data = exportData() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "aevis-memory-\(formatter.string(from: Date())).json"
        let url = backupDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            trimSnapshots(keep: 20)
            statusLine = "已存一份快照：\(name)"
            return name
        } catch {
            statusLine = "存快照失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 本地快照列表（新的在前）。
    func snapshots() -> [(name: String, url: URL, date: Date, size: Int)] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> (String, URL, Date, Int)? in
                let url = backupDirectory.appendingPathComponent(name)
                let attributes = try? manager.attributesOfItem(atPath: url.path)
                let date = (attributes?[.creationDate] as? Date) ?? Date.distantPast
                let size = (attributes?[.size] as? Int) ?? 0
                return (name, url, date, size)
            }
            .sorted { $0.2 > $1.2 }
    }

    func restore(snapshot url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            statusLine = "这个快照读不出来。"
            return
        }
        items.removeAll()
        _ = importData(data)
        statusLine = "已从快照恢复，当前 \(items.count) 条。"
    }

    func delete(snapshot url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func trimSnapshots(keep: Int) {
        let list = snapshots()
        guard list.count > keep else { return }
        for entry in list.dropFirst(keep) {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }

    private struct BackupPayload: Codable {
        var app: String
        var version: Int
        var exportedAt: Date
        var items: [MemoryItem]
    }
}
