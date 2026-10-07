import Foundation

/// 群聊的本地存储。**全部存在这台设备上。**
///
/// ## 为什么是**全局**的，而不是「按联系人分开存」
/// 别的 Store（聊天 / 记忆 / 朋友圈 / 日记 / 待办 / ta的小手机）都是「按联系人
/// 分开存」的，因为它们的内容**属于某一个人**。群不一样 —— 群不属于任何单个人，
/// 它本身就是一个会话。所以这里**不挂** `PersonaStore.broadcastSwitch`。
///
/// ⚠️ 由此带来的两条「以后加东西要注意」：
///    · 群成员被删掉时，群里的那个 id 会变成**悬空**的。消费方（`GroupChatService`）
///      要自己跳过找不到的人 —— 这里**不**主动删成员，因为 `PersonaStore.remove`
///      （那个真正删人的地方）不在本次允许改的范围里。
///    · 但**备份/搬家**这一条必须做（见文件末尾的 `BackupableStore`），
///      并且**自带 `loading` 只读位** —— 跟别的 Store 一个规矩，少一个就搬家搬丢。
final class GroupStore: ObservableObject {
    static let shared = GroupStore()

    /// 所有群。界面按这个顺序列（新的在后面）。
    @Published private(set) var groups: [ChatGroup] = []

    /// 读档 / 搬家导入期间**只读不写**（跟 `CoupleStore.loading` 一个坑）。
    private var loading = false

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-groups.json")
        load()
    }

    // MARK: - 查

    /// 按 id 找一个群。找不到 = 这个 id 不是群（比如是联系人）。
    func group(for id: UUID?) -> ChatGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// 这个 id 是不是一个群。`ChatView` 靠它决定走不走群聊那条路。
    func isGroup(_ id: UUID?) -> Bool { group(for: id) != nil }

    // MARK: - 增删改

    /// 建一个群。
    ///
    /// - 名字去首尾空白；成员去重、并且**至少要 2 个人**（一个 AI 的群不叫群聊）。
    /// - 不满足条件时返回 `nil`，界面据此提示，别静默失败。
    @discardableResult
    func create(name: String, memberIDs: [UUID]) -> ChatGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<UUID>()
        let members = memberIDs.filter { seen.insert($0).inserted }
        guard !trimmed.isEmpty, members.count >= 2 else { return nil }

        let group = ChatGroup(name: trimmed, memberIDs: members)
        groups.append(group)
        save()
        return group
    }

    /// 改一个群（名字 / 成员）。成员同样去重、至少 2 个；不合法就原样不动。
    func update(_ group: ChatGroup) {
        var next = group
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<UUID>()
        next.memberIDs = next.memberIDs.filter { seen.insert($0).inserted }
        guard !next.name.isEmpty, next.memberIDs.count >= 2 else { return }
        guard let index = groups.firstIndex(where: { $0.id == next.id }) else { return }
        groups[index] = next
        save()
    }

    /// 删一个群。（它的聊天记录由调用方决定要不要一起清 —— 见 `ChatStore.forget`。）
    func remove(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var groups: [ChatGroup] = []
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间禁写，理由同 `ChatStore.load()`。
        loading = true
        defer { loading = false }
        groups = archived.groups
    }

    private func save() {
        guard !loading else { return }
        writeArchive()
    }

    private func writeArchive() {
        let archive = Archive(groups: groups)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 备份与搬家

extension GroupStore: BackupableStore {
    var backupName: String { "groups" }

    func exportBackup() throws -> Data {
        try JSONEncoder().encode(Archive(groups: groups))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入期间禁写 —— 跟别的 Store 同理，防止中途那次 save 把刚读进来的盖掉。
        loading = true
        defer { loading = false }
        groups = archived.groups
        // loading 还没解除，这里显式落盘
        writeArchive()
    }
}
