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

    /// ⭐ 记忆网：这条记忆**连着**哪几条（存对方的 `id`）。
    ///
    /// 为什么要它：原来记忆就是一列平铺的句子，条目之间毫无关系 ——
    /// 模型看到的是"几条孤立的句子"，自然想不起旧事来。
    /// 有了它，「搬家」这条能牵出「新房子」「那盆绿萝」「楼下那家面馆」。
    ///
    /// ⚠️ 用 Optional：老存档里**没有这个键**，`decodeIfPresent` 得 nil、不抛错
    ///    （跟 `WalletStore.Entry` 同一个套路）。读写一律走 `linkIDs`。
    var links: [String]? = nil

    /// 只读口子：没连任何东西时给空数组，调用方不用到处 `?? []`。
    var linkIDs: [String] { links ?? [] }
}

/// 长期记忆库。
///
/// 三件事：
/// 1. **自动提炼** —— 聊够一段就让ta把「值得长期记住」的挑出来存下；
/// 2. **手动管理** —— 能加、能改、能删、能钉；
/// 3. **备份** —— 导出成 JSON，也留本地快照，能一键恢复。
///
/// 全部只存在这台手机上（备份文件在 App 自己的目录里）。
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    /// 当前联系人的长期记忆（老入口，保持不变）。
    @Published private(set) var items: [MemoryItem] = []

    /// 每个人的记忆分开放 —— 不然换了人之后ta还会「记得」上一个人的事，
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

    /// 正在织网（供界面显示进度）。
    @Published private(set) var weaving = false

    /// 上次织网时条目有多少条 —— 没变就不必再花一次模型调用。
    private var wovenCount = -1

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
        // ⚠️ 读档 / 搬家期间禁写，理由同 `ChatStore.load()`：
        //    紧接着的 `setOwner` 会先 `stash()`，用旧机器的 `items` 盖掉刚搬进来的。
        loading = true
        defer { loading = false }
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
    /// 正在「搬家」导入 / 启动读档 —— 期间只读不写。
    /// 细节见 `ChatStore.loading`（同一条链路上同一个 bug）。
    private var loading = false

    private func stash() {
        guard !loading else { return }
        if let owner { byOwner[owner] = items }
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    /// 把 `byOwner` 原样落盘，不经过 `stash()`。导入时用。
    private func writeArchive() {
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
        pruneLinks(to: item.id)
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
    /// 记忆太多会挤掉真正的对话，反而让ta变笨。
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

    // MARK: - 记忆网（一条连一条）

    /// ⭐ **织网**：让ta自己找出「哪几条记忆是有关系的」，写成一条条连线。
    ///
    /// 为什么不用关键词匹配：中文里「他住在杭州」和「他搬到杭州」**一个词都不重合**，
    /// 按字面根本连不起来；「他们上个月吵过架」和「她说最近心里不踏实」更是完全不同的字。
    /// 这种语义上的关系只有模型看得出来，所以把编号喂给它、让它自己认。
    ///
    /// 输出约定：只输出有关系的一对一对（`3-7`），别的什么都不说。
    /// **解析不出来就原样保留已有连线，绝不清空** —— 宁可不织，也不能把网弄没。
    ///
    /// - Parameter force: 界面上的「重新织网」按钮传 true（跳过"条目数没变就不重织"的判断）。
    @MainActor
    func weaveLinks(config: LLMConfig, force: Bool = false) async {
        guard !weaving else { return }
        guard config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }
        let snapshot = items
        guard snapshot.count >= 2 else { return }
        // 条目太多就别织了 —— 提示词会太长、模型也会糊，画出来也是一团毛线。
        guard snapshot.count <= 200 else { return }
        if !force, wovenCount == snapshot.count { return }

        weaving = true
        defer { weaving = false }

        let list = snapshot.enumerated().map { index, item in
            "\(index + 1). [\(item.kind.label)] \(item.text)"
        }.joined(separator: "\n")

        let instruction = """
        下面是一份记忆清单，每条前面有编号。
        请找出**彼此有关系**的条目：同一个人、同一个地方、同一件事，或者后者是前者的起因/结果。

        只输出编号对，一行一对，用短横线隔开，比如：
        3-7
        12-31

        要求：
        - 只输出编号对，**不要**任何解释、标题、标点或多余文字。
        - 只连**真正相关**的，不要为了凑数硬连；每条最多连 4 条。
        - 完全没有相关的就什么都不输出。

        --- 记忆清单 ---
        \(list)
        """

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: "你是一个把笔记连成网的助手。严格只输出要求的格式，不要解释。",
                history: [ChatMessage(role: .user, text: instruction)],
                memory: []
            ) {
                collected += piece
                if collected.count > 4000 { break }
            }
        } catch {
            return
        }

        let pairs = Self.parsePairs(collected)
        guard !pairs.isEmpty else { return }

        var linked: [String: [String]] = [:]
        for pair in pairs {
            guard pair.a >= 1, pair.a <= snapshot.count,
                  pair.b >= 1, pair.b <= snapshot.count,
                  pair.a != pair.b else { continue }
            let left = snapshot[pair.a - 1].id
            let right = snapshot[pair.b - 1].id
            linked[left, default: []].append(right)
            linked[right, default: []].append(left)
        }
        guard !linked.isEmpty else { return }

        var changed = false
        for index in items.indices {
            let id = items[index].id
            var picked = Array(Set(linked[id] ?? [])).sorted()
            if picked.count > 4 { picked = Array(picked.prefix(4)) }
            if (items[index].links ?? []) != picked {
                items[index].links = picked.isEmpty ? nil : picked
                changed = true
            }
        }
        guard changed else { return }
        save()
        wovenCount = items.count
        statusLine = "记忆网织好了。"
    }

    /// 解析 `3-7` 这种行。模型偶尔会写歪（`3 - 7`、`3,7`、`3、7`、`3—7`），尽量宽容。
    private static func parsePairs(_ raw: String) -> [(a: Int, b: Int)] {
        let separators = CharacterSet(charactersIn: "-—–~～,，、/|:：;；.。")
            .union(.whitespaces)
        // ⚠️ **整行只允许出现数字和分隔符** —— 一行里混进汉字，多半是模型没听话、
        //    把清单原样抄回来了（"去年 5 月搬到杭州，住了 3 年"）。那种行里随便
        //    两个数字都会被当成一对，**凭空连出一条错线**，比不连更糟。
        let allowed = CharacterSet.decimalDigits.union(separators)
        var result: [(Int, Int)] = []
        for rawLine in raw.split(separator: "\n") {
            guard rawLine.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            let numbers = rawLine
                .components(separatedBy: separators)
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 2,
                  let a = numbers.first,
                  let b = numbers.dropFirst().first,
                  a != b else { continue }
            result.append((a, b))
        }
        return result
    }

    /// 删掉一条记忆之后，把别人指向它的连线清干净 ——
    /// 不然网上会留着指向虚空的线。
    private func pruneLinks(to removedID: String) {
        for index in items.indices {
            guard var list = items[index].links, list.contains(removedID) else { continue }
            list.removeAll { $0 == removedID }
            items[index].links = list.isEmpty ? nil : list
        }
        wovenCount = -1
    }

    // MARK: - 自动提炼

    /// 聊得够多了就提炼一次。
    /// - Parameter messageCount: 当前对话总条数
    @MainActor
    func extractIfNeeded(config: LLMConfig, messages: [ChatMessage], persona: Persona, force: Bool = false) async {
        guard !working else { return }
        guard config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return }

        let threshold = AppSettings.shared.memoryExtractEvery
        let pending = messages.count - extractedUpTo
        guard force || pending >= threshold else { return }

        // 只把最近这段给ta看，不用把整段历史塞进去
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

        // ⭐ 新记忆进来之后顺手把网重织一遍 —— 新条目多半要跟老的挂上钩。
        //    方法自身有 `weaving` 重入保护 + "条目数没变就不重织"的判断，
        //    这里不用额外节流。
        if added > 0 { await weaveLinks(config: config) }
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

// MARK: - 备份与搬家

extension MemoryStore: BackupableStore {
    var backupName: String { "memory" }

    /// 导出**所有人的**记忆，不只当前这个 ——
    /// 类里已有的 `exportData()` 只导当前联系人那份，搬家要搬的是全部。
    func exportBackup() throws -> Data {
        stash()
        let flat = byOwner.reduce(into: [String: [MemoryItem]]()) { result, item in
            result[item.key.uuidString] = item.value
        }
        return try JSONEncoder().encode(Archive(byOwner: flat))
    }

    func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入全程禁写：中途 `PersonaStore.broadcastSwitch` 会调 `setOwner`，
        //    那一下要是允许 `stash()`，刚搬进来的记忆当场被旧机器的 `items` 顶掉。
        loading = true
        defer { loading = false }
        byOwner = archive.byOwner.reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.key) else { return }
            result[id] = item.value
        }
        items = owner.flatMap { byOwner[$0] } ?? []
        // 上面的 loading 还没解除，这里显式落盘
        writeArchive()
    }
}
