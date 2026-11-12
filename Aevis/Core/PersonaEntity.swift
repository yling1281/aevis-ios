// 快捷指令里的「发给谁」（2026-11-12）
//
// 用户：「快捷指令也要加之类的……全都是要选的」。
//
// AppIntents 要在「快捷指令」编辑器里给出可选项，必须是一个 `AppEntity` +
// `EntityQuery`。这里把通讯录里的角色暴露出去；用户在系统快捷指令里
// 就能选「发给谁」，不选就落到上次那个人（`PersonaMemory`）。
import AppIntents
import Foundation

struct PersonaEntity: AppEntity, Identifiable, Hashable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "角色")
    static var defaultQuery = PersonaEntityQuery()

    /// `PersonaStore` 里那个 UUID 的字符串形式。
    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    /// 转回真正的 UUID。
    var uuid: UUID? { UUID(uuidString: id) }
}

struct PersonaEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PersonaEntity] {
        let want = Set(identifiers.compactMap { UUID(uuidString: $0) })
        let all = await MainActor.run { PersonaEntityQuery.snapshot() }
        return all.filter { want.contains(UUID(uuidString: $0.id) ?? UUID()) }
    }

    func suggestedEntities() async throws -> [PersonaEntity] {
        await MainActor.run { PersonaEntityQuery.snapshot() }
    }

    /// 不选的时候用谁 —— 上次在快捷指令里选的那个，没有就用当前角色。
    func defaultResult() async -> PersonaEntity? {
        await MainActor.run {
            let memory = PersonaMemory.shared.last(for: PersonaMemory.Feature.shortcut)
            let store = PersonaStore.shared
            let target = memory.first ?? store.active?.id
            guard let id = target,
                  let contact = store.contacts.first(where: { $0.id == id }) else {
                return PersonaEntityQuery.snapshot().first
            }
            return PersonaEntity(id: contact.id.uuidString, name: contact.displayName)
        }
    }

    @MainActor
    static func snapshot() -> [PersonaEntity] {
        PersonaStore.shared.contacts.map {
            PersonaEntity(id: $0.id.uuidString, name: $0.displayName)
        }
    }
}

extension PersonaEntity {
    /// 解析成真正的联系人；传空就落到默认（上次 / 当前）。
    @MainActor
    func resolvedContact(feature: String = PersonaMemory.Feature.shortcut) -> Contact? {
        let store = PersonaStore.shared
        if let id = uuid, let c = store.contacts.first(where: { $0.id == id }) {
            PersonaMemory.shared.remember([id], for: feature)
            return c
        }
        if let id = PersonaMemory.shared.defaultOne(for: feature),
           let c = store.contacts.first(where: { $0.id == id }) {
            return c
        }
        return store.contacts.first
    }
}
