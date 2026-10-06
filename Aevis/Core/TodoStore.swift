import Foundation

/// 一件「想和 ta 一起做的事」。
///
/// 用户 2026-10-04 看完电脑版之后要的：「手机端也同步这些」——
/// 待办就是其中一块。**文案走温馨甜蜜那一挂**（老板原话：
/// 「就是那种很温馨、很甜蜜的」），所以别把它写成一个任务管理器：
/// 这里是"我们的清单"，不是"待办事项"。
struct TodoItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = ""
    /// 做完了没有。做完的沉到底下，并划一道线。
    var done: Bool = false
    /// 附一句（可以不写）。比如「下周三之前」。
    var note: String = ""
    /// true = 我提的；false = ta 提的。列表里据此标一下。
    var byMe: Bool = true
    var createdAt: Date = Date()
    /// 哪一刻打上的勾。没做完就是 nil。
    var doneAt: Date?
}

/// 「一起做的事」清单 —— **按联系人分开存**。
///
/// 跟日记 / 记忆 / 朋友圈一个道理：换个人不该看到上一个人的清单。
/// 切人由 `PersonaStore.broadcastSwitch` 统一通知。
///
/// ⚠️ 新加「按人分开存」的 Store 时，**两件事必须一起做**（漏一个就是 bug）：
///    ① 在 `PersonaStore.broadcastSwitch` / `remove` 里挂号；
///    ② 自己带 `loading` 标志位，并进 `BackupService.stores()`。
///    漏掉 ① 是「换了人还看着上一个人的」，漏掉 ② 是「搬家搬丢」。
final class TodoStore: ObservableObject {
    static let shared = TodoStore()

    /// 当前联系人的清单（没排序，界面用 `ordered`）。
    @Published private(set) var items: [TodoItem] = []

    private var itemsByOwner: [UUID: [TodoItem]] = [:]
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**（同 `CoupleStore.loading`）。
    private var loading = false

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-todo-by-contact.json")
        load()
    }

    // MARK: - 切人

    func setOwner(_ id: UUID?) {
        stash()
        owner = id
        guard let id else {
            items = []
            return
        }
        items = itemsByOwner[id] ?? []
    }

    func forget(_ id: UUID) {
        itemsByOwner[id] = nil
        if owner == id { items = [] }
        save()
    }

    // MARK: - 增减改

    @discardableResult
    func add(_ item: TodoItem) -> UUID {
        var value = item
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { return value.id }
        items.append(value)
        save()
        return value.id
    }

    /// 打勾 / 取消打勾。做完顺手记一个时刻。
    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done.toggle()
        items[index].doneAt = items[index].done ? Date() : nil
        save()
    }

    func update(_ item: TodoItem) {
        var value = item
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.title.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.id == value.id }) else { return }
        // 只在"这次真的改了完成状态"时动 doneAt，别把时刻刷成现在
        if items[index].done != value.done {
            value.doneAt = value.done ? Date() : nil
        }
        items[index] = value
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// 还没做的有多少件。
    var openCount: Int {
        items.filter { !$0.done }.count
    }

    /// 界面上用的顺序：**没做完的在上面**（新的在前），做完的沉到底下。
    var ordered: [TodoItem] {
        let open = items.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt }
        let done = items.filter { $0.done }.sorted { ($0.doneAt ?? $0.createdAt) > ($1.doneAt ?? $1.createdAt) }
        return open + done
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var items: [String: [TodoItem]] = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }

    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        itemsByOwner[owner] = items
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    private func writeArchive() {
        guard !itemsByOwner.isEmpty else { return }
        let archive = Archive(items: flatItems())
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func flatItems() -> [String: [TodoItem]] {
        itemsByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }
}

// MARK: - 备份与搬家

extension TodoStore: BackupableStore {
    var backupName: String { "todo" }

    func exportBackup() throws -> Data {
        stash()
        return try JSONEncoder().encode(Archive(items: flatItems()))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        items = owner.flatMap { itemsByOwner[$0] } ?? []
        writeArchive()
    }
}
