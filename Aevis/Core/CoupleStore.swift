import Foundation

// MARK: - 一条倒数日

/// 一条倒数日 / 纪念日。
///
/// 用户 2026-10-01 原话：「情侣空间倒数日，你写代码呀。
/// 倒数日可以自己添加情侣空间，也可以绑定情侣」。
///
/// ⚠️ **只care年月日** —— 存到时分秒的话，「还有 1 天」会因为
/// 今天 11:30、目标时刻 00:00 而当场变成 0 天（"就是今天"），
/// 倒数日最忌讳这个。所以存进来的第一天就被 `startOfDay` 抹平。
struct Anniversary: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = ""
    /// 目标日子。**只取年月日**。
    var date: Date = Date()
    /// 每年重复 —— 生日、周年这种。不重复的过完就一直是「已过 N 天」。
    var yearly: Bool = false
    var note: String = ""
    /// 是 ta 自己在聊天里加的（界面上标一下，用户才知道这条哪来的）。
    var byAI: Bool = false
}

extension Anniversary {

    /// 今天到这一天还有几天。今天就是那天 → `0`；已经过了 → 负数。
    ///
    /// - 每年重复：永远算**下一次**（今年过了就说明年那次），所以不会是负数；
    /// - 一次性：就是目标日本身，过了就是负数（界面显示「已过 N 天」）。
    func daysLeft(_ today: Date = Date()) -> Int {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: today)
        let target = calendar.startOfDay(for: occurring(after: now))
        return calendar.dateComponents([.day], from: now, to: target).day ?? 0
    }

    /// 这一条「下一次」落在哪天。
    private func occurring(after today: Date) -> Date {
        guard yearly else { return date }
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.month, .day], from: date)
        parts.year = calendar.component(.year, from: today)
        // ⚠️ 2 月 29 日在平年 `date(from:)` 会给 nil —— 退回原日期，
        //    总比"这条纪念日今年凭空消失"强（这种日期本来就少见）。
        var next = calendar.date(from: parts) ?? date
        if next < today {
            parts.year = (parts.year ?? 0) + 1
            next = calendar.date(from: parts) ?? next
        }
        return next
    }

    /// 「还有 12 天」/「就是今天」/「已过 3 天」。
    func daysText(_ today: Date = Date()) -> String {
        let days = daysLeft(today)
        if days == 0 { return "就是今天" }
        return days > 0 ? "还有 \(days) 天" : "已过 \(-days) 天"
    }
}

// MARK: - 情侣空间

/// 情侣空间 —— **在一起的日子 + 倒数日**。
///
/// ⚠️ 这东西用户 **2026-09-27 就点名要过**，一直挂到今天才动手
/// （`grep 情侣空间\|倒数日` 当时在全部 Swift 里 0 命中）。
///
/// **按联系人分开存** —— 跟记忆 / 朋友圈一个道理：通讯录里有好几个人时，
/// 换个人不该看到上一个人的纪念日。切人由 `PersonaStore.broadcastSwitch` 统一通知。
///
/// 「绑定情侣」= 给当前这个 ta 设一个**在一起的开始日**。
/// 绑定之后情侣空间顶上就有「在一起第 N 天」，
/// 不绑定则只有一个「绑定情侣」按钮 —— 倒数日本身不依赖绑定，随时能用。
final class CoupleStore: ObservableObject {
    static let shared = CoupleStore()

    /// 当前联系人的倒数日（没排序，界面用 `upcoming`）。
    @Published private(set) var anniversaries: [Anniversary] = []

    /// 当前联系人「在一起」的第一天。没绑过就是 nil。
    @Published private(set) var togetherSince: Date?

    /// 每个人的分开存。
    private var itemsByOwner: [UUID: [Anniversary]] = [:]
    private var sinceByOwner: [UUID: Date] = [:]
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**。
    ///
    /// ⚠️ 和 `ChatStore.loading` / `MemoryStore.loading` 是**同一个坑**：
    /// 导入时 `PersonaStore.broadcastSwitch` 会调 `setOwner`，那一下要是允许
    /// `stash()`，刚搬进来的数据当场被旧机器内存里那份顶掉。
    private var loading = false

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-couple-by-contact.json")
        load()
    }

    // MARK: - 切人

    /// 切到某个联系人。`PersonaStore` 切人时来调。
    func setOwner(_ id: UUID?) {
        stash()
        owner = id

        guard let id else {
            anniversaries = []
            togetherSince = nil
            return
        }
        anniversaries = itemsByOwner[id] ?? []
        togetherSince = sinceByOwner[id]
    }

    /// 把某个联系人的整块删掉（删联系人时用）。
    func forget(_ id: UUID) {
        itemsByOwner[id] = nil
        sinceByOwner[id] = nil
        if owner == id {
            anniversaries = []
            togetherSince = nil
        }
        save()
    }

    // MARK: - 绑定情侣

    var isBound: Bool { togetherSince != nil }

    /// 绑定（或改）「在一起」的第一天。
    func bind(since date: Date) {
        guard let owner else { return }
        let day = Calendar.current.startOfDay(for: date)
        togetherSince = day
        sinceByOwner[owner] = day
        save()
    }

    func unbind() {
        guard let owner else { return }
        togetherSince = nil
        sinceByOwner[owner] = nil
        save()
    }

    /// 在一起多少天。没绑定 → nil。
    ///
    /// 习惯上「在一起那天」就算第 1 天，所以 +1。
    /// 用户把日期填到未来时夹到 1（`max(0, ...)`），免得显示成「第 0 天」。
    var daysTogether: Int? {
        guard let togetherSince else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: togetherSince)
        let today = calendar.startOfDay(for: Date())
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(0, days) + 1
    }

    // MARK: - 增减改

    @discardableResult
    func add(_ anniversary: Anniversary) -> UUID {
        var item = anniversary
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.title.isEmpty else { return item.id }
        item.date = Calendar.current.startOfDay(for: item.date)
        anniversaries.append(item)
        save()
        return item.id
    }

    func update(_ anniversary: Anniversary) {
        var item = anniversary
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !item.title.isEmpty else { return }
        item.date = Calendar.current.startOfDay(for: item.date)
        guard let index = anniversaries.firstIndex(where: { $0.id == item.id }) else { return }
        anniversaries[index] = item
        save()
    }

    func remove(_ id: UUID) {
        anniversaries.removeAll { $0.id == id }
        save()
    }

    /// 界面上用的顺序：**最近的排最前**，已经过去的沉到底。
    var upcoming: [Anniversary] {
        anniversaries.sorted { left, right in
            let l = left.daysLeft()
            let r = right.daysLeft()
            // 负数（已过）永远排在非负数后面
            if (l < 0) != (r < 0) { return l >= 0 }
            // 都在未来：越近越前；都已过去：越新（-3 在 -30 前面）越前
            return l < r
        }
    }

    // MARK: - 给模型看的那段

    /// 一段纯文本，喂给模型 —— 让ta知道纪念日，聊天时能自然提起。
    func injectedLines() -> [String] {
        var lines: [String] = []
        if let days = daysTogether, let since = togetherSince {
            lines.append("- 你们在一起第 \(days) 天（\(Self.dayText(since))）")
        }
        for item in upcoming.prefix(12) {
            let repeatText = item.yearly ? "，每年" : ""
            lines.append("- \(item.title)：\(Self.dayText(item.date))\(repeatText) —— \(item.daysText())")
        }
        return lines
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var items: [String: [Anniversary]] = [:]
        var since: [String: Date] = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间禁写，理由同 `ChatStore.load()`：紧接着的 `setOwner` 会先
        //    `stash()`，用旧机器的那份盖掉刚读进来的。
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        sinceByOwner = archived.since.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }

    /// 把当前这份写回字典。任何落盘之前都要先做一次。
    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        itemsByOwner[owner] = anniversaries
        sinceByOwner[owner] = togetherSince
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    /// 把 `byOwner` 原样落盘，**不经过 `stash()`**。导入时用。
    private func writeArchive() {
        // 两边都空就不落盘 —— 否则第一次启动还没认人就会写一份空存档。
        guard !itemsByOwner.isEmpty || !sinceByOwner.isEmpty else { return }
        let archive = Archive(items: flatItems(), since: flatSince())
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func flatItems() -> [String: [Anniversary]] {
        itemsByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }

    private func flatSince() -> [String: Date] {
        sinceByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }
}

// MARK: - 备份与搬家

extension CoupleStore: BackupableStore {
    var backupName: String { "couple" }

    func exportBackup() throws -> Data {
        stash()
        return try JSONEncoder().encode(Archive(items: flatItems(), since: flatSince()))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入全程禁写，理由同 `MemoryStore.importBackup` ——
        //    中途切人那一下的 `stash()` 会把刚搬进来的盖掉。
        loading = true
        defer { loading = false }
        itemsByOwner = archived.items.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        sinceByOwner = archived.since.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        anniversaries = owner.flatMap { itemsByOwner[$0] } ?? []
        togetherSince = owner.flatMap { sinceByOwner[$0] }
        // 上面的 loading 还没解除，这里显式落盘
        writeArchive()
    }
}
