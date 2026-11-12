// 按功能记住「上次选的人」（2026-11-12）
//
// 用户：「点一下可以选择多个人啊，不是说最近活跃的……默认是上一次的人，就是记忆吧」。
//
// 所以每个功能（一起听 / 打电话 / 情侣空间 / 一起做 / 发朋友圈 / 听音乐）
// 各自记一份"上次选了谁"，下次打开默认就是那一份，不是"当前活跃角色"。
//
// 存 UserDefaults，值是一个 UUID 数组。联系人被删掉时读出来会自动过滤 ——
// 不做清理也不会选到一个已经不存在的人。
import Foundation

@MainActor
final class PersonaMemory {
    static let shared = PersonaMemory()

    /// 功能键。加新功能时在这里补一个常量，别到处写裸字符串。
    enum Feature {
        /// 一起听
        static let listen = "listen"
        /// 一起做（一起看电影 / 一起玩）
        static let together = "together"
        /// 打电话
        static let call = "call"
        /// 情侣空间
        static let couple = "couple"
        /// 发朋友圈
        static let moment = "moment"
        /// 听音乐
        static let music = "music"
        /// 快捷指令
        static let shortcut = "shortcut"
    }

    private let prefix = "aevis.pick."

    private init() {}

    /// 上次选的人。没人选过 / 全都删了 → 返回空集合。
    func last(for feature: String) -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: prefix + feature) ?? []
        let ids = raw.compactMap { UUID(uuidString: $0) }
        let alive = Set(PersonaStore.shared.contacts.map(\.id))
        return Set(ids).intersection(alive)
    }

    /// 记住这次的选择。
    func remember(_ ids: Set<UUID>, for feature: String) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: prefix + feature)
    }

    /// 默认选中：上次那份 → 没有就用当前活跃那个（保证永远有个能用的默认值）。
    func defaultSelection(for feature: String) -> Set<UUID> {
        let saved = last(for: feature)
        if !saved.isEmpty { return saved }
        if let active = PersonaStore.shared.active?.id { return [active] }
        return []
    }

    /// 单选场景的默认值。
    func defaultOne(for feature: String) -> UUID? {
        if let saved = last(for: feature).first { return saved }
        return PersonaStore.shared.active?.id ?? PersonaStore.shared.contacts.first?.id
    }

    func clear(for feature: String) {
        UserDefaults.standard.removeObject(forKey: prefix + feature)
    }
}
