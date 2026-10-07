import Foundation

/// 一篇日记。
///
/// 用户 2026-10-04 看完电脑版新界面之后说：「手机端也同步这些」——
/// 日记就是其中一块。**两个人写在同一个本子里**，靠 `authorIsMe` 区分
/// 「我写的 / ta 写的」。
///
/// ⚠️ `date` **只取年月日** —— 跟 `Anniversary` 一个道理：
///    日记是按天翻的，时分秒没有意义，留着只会让「今天」这条排得乱七八糟。
struct DiaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// 这一天。**只取年月日**。
    var date: Date = Date()
    var title: String = ""
    var body: String = ""
    /// 心情，一个短词或一个表情。可以不写。
    var mood: String?
    /// true = 我写的；false = ta 写的。列表里据此标一下。
    var authorIsMe: Bool = true
    /// 上锁的那几篇：列表里只露标题，正文要点开验证才看得到。
    ///
    /// ⚠️ 这一档是「**隐私锁**」，不是**加密锁** —— 密码存在本机存档里，
    ///    门槛是"别人借你手机随手点开看不到"，不是"拿到文件也解不开"。
    ///    真加密（忘了密码就永久打不开）留给后面的活，别在这里塞。
    var locked: Bool = false
    /// 写下来的时刻。排序用它（同一天写了多篇时，后来写的在上面）。
    var createdAt: Date = Date()
}

/// 日记 —— **按联系人分开存**。
///
/// 跟记忆 / 朋友圈 / 情侣空间一个道理：通讯录里有好几个人时，
/// 换个人不该看到上一个人的日记。切人由 `PersonaStore.broadcastSwitch` 统一通知。
///
/// ⚠️ 新加「按人分开存」的 Store 时，**两件事必须一起做**（漏一个就是 bug）：
///    ① 在 `PersonaStore.broadcastSwitch` / `remove` 里挂号；
///    ② 自己带 `loading` 标志位，并进 `BackupService.stores()`。
///    漏掉 ① 是「换了人还看着上一个人的」，漏掉 ② 是「搬家搬丢」。
final class DiaryStore: ObservableObject {
    static let shared = DiaryStore()

    /// 当前联系人的日记（没排序，界面用 `sorted`）。
    @Published private(set) var entries: [DiaryEntry] = []

    /// 隐私锁的密码。**空 = 没设锁**，进入日记页不用验证。
    ///
    /// ⚠️ 这个是**整块日记**的锁，不跟着联系人走 —— 换个人还是同一把锁。
    @Published private(set) var pin: String = ""

    /// 每个人的日记分开存。
    private var itemsByOwner: [UUID: [DiaryEntry]] = [:]
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**。
    ///
    /// ⚠️ 和 `CoupleStore.loading` 是同一个坑：导入时 `broadcastSwitch` 会调
    ///    `setOwner`，那一下要是允许 `stash()`，刚搬进来的数据当场被旧机器那份顶掉。
    private var loading = false

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-diary-by-contact.json")
        load()
    }

    // MARK: - 切人

    /// 切到某个联系人。`PersonaStore` 切人时来调。
    func setOwner(_ id: UUID?) {
        stash()
        owner = id
        guard let id else {
            entries = []
            return
        }
        entries = itemsByOwner[id] ?? []
    }

    /// 把某个联系人的整块删掉（删联系人时用）。
    func forget(_ id: UUID) {
        itemsByOwner[id] = nil
        if owner == id { entries = [] }
        save()
    }

    // MARK: - 隐私锁

    var hasPin: Bool { !pin.isEmpty }

    /// 设 / 改 / 清空密码（传空串就是去掉锁）。
    func setPin(_ value: String) {
        pin = value.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// 输入的密码对不对。没设密码时永远返回 false（界面根本不走这条路）。
    func verify(_ value: String) -> Bool {
        guard hasPin else { return false }
        return value == pin
    }

    // MARK: - 增减改

    @discardableResult
    func add(_ entry: DiaryEntry) -> UUID {
        var item = entry
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // 标题和正文都空的直接不要 —— 否则列表里会多出一张点不开的空卡。
        guard !item.title.isEmpty || !item.body.isEmpty else { return item.id }
        item.date = Calendar.current.startOfDay(for: item.date)
        entries.append(item)
        save()
        return item.id
    }

    func update(_ entry: DiaryEntry) {
        var item = entry
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = entries.firstIndex(where: { $0.id == item.id }) else { return }
        item.date = Calendar.current.startOfDay(for: item.date)
        entries[index] = item
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// 界面上用的顺序：**新的排最前**（同一天里后写的在上面）。
    var sorted: [DiaryEntry] {
        entries.sorted { left, right in
            if left.date != right.date { return left.date > right.date }
            return left.createdAt > right.createdAt
        }
    }

    /// 「2026 年 10 月 4 日」。
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var items: [String: [DiaryEntry]] = [:]
        /// 🔴 **必须可选项** —— Swift 合成的 `Decodable` 不吃属性默认值：
        ///    写成 `var pin: String = ""` 时，**没有这个 key 的老存档**
        ///    （还没有「日记隐私锁」的版本导出的）会直接抛 `keyNotFound`，
        ///    整份日记解不出 ⇒ 本机静默清空 / 网盘恢复中断。
        ///    老存档缺这个键 ⇒ nil，读的时候 `?? ""` 兜底。
        var pin: String? = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间禁写，理由同 `CoupleStore.load()`。
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        pin = archived.pin ?? ""
    }

    /// 把当前这份写回字典。任何落盘之前都要先做一次。
    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        itemsByOwner[owner] = entries
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    /// 把 `byOwner` 原样落盘，**不经过 `stash()`**。导入时用。
    private func writeArchive() {
        // 两边都空就不落盘 —— 否则第一次启动还没认人就会写一份空存档。
        guard !itemsByOwner.isEmpty || !pin.isEmpty else { return }
        let archive = Archive(items: flatItems(), pin: pin)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func flatItems() -> [String: [DiaryEntry]] {
        itemsByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }
}

// MARK: - 备份与搬家

extension DiaryStore: BackupableStore {
    var backupName: String { "diary" }

    func exportBackup() throws -> Data {
        stash()
        return try JSONEncoder().encode(Archive(items: flatItems(), pin: pin))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入全程禁写，理由同 `CoupleStore.importBackup`。
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        pin = archived.pin ?? ""
        entries = owner.flatMap { itemsByOwner[$0] } ?? []
        // 上面的 loading 还没解除，这里显式落盘
        writeArchive()
    }
}
