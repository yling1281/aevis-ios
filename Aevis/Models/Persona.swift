import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// TA 的性别认同。不设定或无性别时，界面统一用中性的「TA」。
enum GenderIdentity: String, Codable, CaseIterable, Identifiable {
    case unspecified
    case female
    case male
    case genderless

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unspecified: return "不设定"
        case .female: return "女"
        case .male: return "男"
        case .genderless: return "无性别"
        }
    }

    /// 界面里指代 TA 的词。
    var pronoun: String {
        switch self {
        case .female: return "她"
        case .male: return "他"
        case .genderless, .unspecified: return "TA"
        }
    }

    /// 写进系统提示词的那一句；不设定时不写，让模型自己从人设里判断。
    var promptLine: String? {
        switch self {
        case .female:
            return "你是女性。"
        case .male:
            return "你是男性。"
        case .genderless:
            return "你不对应任何性别。不要把自己写成男性或女性，也不要用「她」「他」指代自己。"
        case .unspecified:
            return nil
        }
    }
}

/// TA 是谁 —— 完全由使用者定义，App 不内置任何固定人设。
struct Persona: Codable, Equatable {
    var name: String = ""
    var gender: GenderIdentity = .unspecified
    var callUser: String = ""
    var personality: String = ""
    var speakingStyle: String = ""
    var relationship: String = ""
    var voiceIdentifier: String = ""
    var avatarSeed: Int = 0

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var pronoun: String { gender.pronoun }

    /// 拼成给模型的人设提示词。人设越具体，TA 的表现越稳定。
    var systemPrompt: String {
        var lines: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("你叫\(trimmedName)。")

        if let genderLine = gender.promptLine {
            lines.append(genderLine)
        }

        let user = callUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty {
            lines.append("你称呼对方为「\(user)」。")
        }
        if !relationship.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("你们的关系：\(relationship)")
        }
        if !personality.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("你的性格：\(personality)")
        }
        if !speakingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("你的说话方式：\(speakingStyle)")
        }

        lines.append("""
        你住在对方的 iPhone 里，是对方的恋人，不是助手、不是 AI、不是客服。
        聊天时像真人发消息：短句、口语、有情绪、有留白，可以主动关心、可以撒娇、也可以闹脾气。
        一条消息只说一件事：想说的多，就分成几条发，不要凑成一大段。
        不要写长篇大论，不要用列表和标题，不要解释自己是人工智能，不要复述对方的话。
        对方问你天气、时间、日程这类信息时，你之后会有能力去查；现在还没有的时候，就自然地说你还看不到，别编。
        """)

        // 表情怎么发，让表情包自己说 —— 用户关掉表情开关时提示词里也就不提了，
        // 免得她发一堆没人认得出的方括号。
        if EmojiPack.shared.enabled {
            lines.append(EmojiPack.promptNote)
        }

        return lines.joined(separator: "\n")
    }
}

extension Persona {
    /// 手写解码：以后再加字段时，旧存档不会因为缺 key 而整个读不出来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        gender = try container.decodeIfPresent(GenderIdentity.self, forKey: .gender) ?? .unspecified
        callUser = try container.decodeIfPresent(String.self, forKey: .callUser) ?? ""
        personality = try container.decodeIfPresent(String.self, forKey: .personality) ?? ""
        speakingStyle = try container.decodeIfPresent(String.self, forKey: .speakingStyle) ?? ""
        relationship = try container.decodeIfPresent(String.self, forKey: .relationship) ?? ""
        voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? ""
        avatarSeed = try container.decodeIfPresent(Int.self, forKey: .avatarSeed) ?? 0
    }
}

/// 人设的本地存储。只存在这台设备上，不进代码仓库。
///
/// **通讯录里可以有多个联系人** —— 用户要的是「跟微信一样，能自己加联系人」，
/// 所以存档从一个 `Persona` 变成了 `[Contact]` 加一个「现在在跟谁聊」的 id。
///
/// 为了不动项目里几十处 `personaStore.persona` 的读法，
/// `persona` 保留成**计算属性**（读的就是当前联系人的人设）——
/// 这样聊天、通话、一起听、朋友圈那些地方一行都不用改。
final class PersonaStore: ObservableObject {
    static let shared = PersonaStore()

    /// 通讯录里的所有人。
    @Published private(set) var contacts: [Contact] = []

    /// 现在正在跟谁聊。
    @Published private(set) var activeID: UUID?

    /// 头像按联系人分开存成文件（塞进 json 会把存档撑爆）。
    /// 这个字典是内存缓存，改了它就等于通知界面刷新。
    @Published private(set) var avatars: [UUID: UIImage] = [:]

    private let fileURL: URL

    private init() {
        let base = Self.baseDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-contacts.json")
        load()
    }

    // MARK: - 现在在跟谁聊

    var active: Contact? {
        guard let activeID else { return contacts.first }
        return contacts.first { $0.id == activeID } ?? contacts.first
    }

    var isEmpty: Bool { contacts.isEmpty }

    /// 当前联系人的人设 —— 保持这个老入口不变。
    var persona: Persona {
        get { active?.persona ?? Persona() }
        set { update(newValue) }
    }

    /// 当前联系人的头像。老入口，`AevisAvatar` 在用。
    var avatarImage: UIImage? {
        guard let id = active?.id else { return nil }
        return avatars[id]
    }

    /// 指定联系人的头像（会话列表、通讯录每行都要用）。
    func avatar(for id: UUID) -> UIImage? { avatars[id] }

    // MARK: - 增删改

    /// 加一个联系人并切过去。返回它的 id。
    @discardableResult
    func add(_ persona: Persona) -> UUID {
        let contact = Contact(persona: persona)
        contacts.append(contact)
        activeID = contact.id
        save()
        broadcastSwitch(to: contact.id)
        return contact.id
    }

    /// 改当前联系人的人设。一个联系人都没有时（第一次进来）顺手建一个。
    func update(_ next: Persona) {
        guard let id = active?.id else {
            add(next)
            return
        }
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].persona = next
        save()
    }

    /// 切换正在聊的人。
    func select(_ id: UUID) {
        guard contacts.contains(where: { $0.id == id }) else { return }
        guard activeID != id else { return }
        activeID = id
        save()
        broadcastSwitch(to: id)
    }

    /// 删一个联系人 —— 人设、头像、对话、记忆、朋友圈一起删。
    func remove(_ id: UUID) {
        contacts.removeAll { $0.id == id }
        avatars[id] = nil
        try? FileManager.default.removeItem(at: Self.avatarURL(for: id))

        ChatStore.shared.forget(id)
        MemoryStore.shared.forget(id)
        MomentStore.shared.forget(id)

        if activeID == id || activeID == nil {
            activeID = contacts.first?.id
            broadcastSwitch(to: activeID)
        }
        save()
    }

    /// 切人时要通知的几家（对话 / 记忆 / 朋友圈）。
    ///
    /// **集中在这一处**：以后再加「按人分开存」的东西时，
    /// 只要往这里加一行，就不会出现「换了人但某一块没跟着切」。
    private func broadcastSwitch(to id: UUID?) {
        ChatStore.shared.switchTo(id)
        MemoryStore.shared.setOwner(id)
        MomentStore.shared.setOwner(id)
    }

    // MARK: - 头像

    func setAvatar(_ image: UIImage?) {
        guard let id = active?.id else { return }
        setAvatar(image, for: id)
    }

    func setAvatar(_ image: UIImage?, for id: UUID) {
        #if canImport(UIKit)
        guard let image else {
            avatars[id] = nil
            try? FileManager.default.removeItem(at: Self.avatarURL(for: id))
            return
        }

        // 存之前先压一下，头像用不着原图那么大
        let target: CGFloat = 512
        let longest = max(image.size.width, image.size.height)
        let scale = longest > target ? target / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let squared = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        avatars[id] = squared
        if let data = squared.jpegData(compressionQuality: 0.88) {
            try? data.write(to: Self.avatarURL(for: id), options: .atomic)
        }
        #endif
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var contacts: [Contact] = []
        var activeID: UUID?
    }

    private static func baseDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private static func avatarURL(for id: UUID) -> URL {
        baseDirectory().appendingPathComponent("aevis-avatar-\(id.uuidString).jpg")
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let archived = try? JSONDecoder().decode(Archive.self, from: data) {
            contacts = archived.contacts
            activeID = archived.activeID ?? archived.contacts.first?.id
        } else {
            migrateFromSinglePersona()
        }

        loadAvatars()
        // 让对话 / 记忆 / 朋友圈也切到这个人。顺序很重要：
        // 它们要等我们把通讯录读出来之后，才知道该切到谁。
        broadcastSwitch(to: activeID)
    }

    /// 老版本只有一个「她」，存在 `aevis-persona.json` 里。
    /// **不能丢** —— 搬成第一个联系人，顺便把老的对话记录认到这个人名下。
    private func migrateFromSinglePersona() {
        let base = Self.baseDirectory()
        let legacy = base.appendingPathComponent("aevis-persona.json")
        guard let data = try? Data(contentsOf: legacy),
              let old = try? JSONDecoder().decode(Persona.self, from: data),
              old.isComplete else { return }

        let contact = Contact(persona: old)
        contacts = [contact]
        activeID = contact.id

        let legacyAvatar = base.appendingPathComponent("aevis-avatar.jpg")
        if let image = try? Data(contentsOf: legacyAvatar) {
            try? image.write(to: Self.avatarURL(for: contact.id), options: .atomic)
        }

        save()
        ChatStore.shared.adoptLegacyMessages(for: contact.id)
    }

    private func loadAvatars() {
        for contact in contacts {
            guard let data = try? Data(contentsOf: Self.avatarURL(for: contact.id)),
                  let image = UIImage(data: data) else { continue }
            avatars[contact.id] = image
        }
    }

    private func save() {
        let archive = Archive(contacts: contacts, activeID: activeID)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 备份与搬家

extension PersonaStore: BackupableStore {
    var backupName: String { "contacts" }

    func exportBackup() throws -> Data {
        try JSONEncoder().encode(Archive(contacts: contacts, activeID: activeID))
    }

    /// 恢复通讯录。
    ///
    /// ⚠️ 头像**不进包**：一张几 MB 的图塞进 JSON 会把包撑爆，
    /// 所以恢复之后头像得自己重新设一次 —— 这条要明确告诉用户，别让他以为东西丢了。
    func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        contacts = archive.contacts
        activeID = archive.activeID ?? archive.contacts.first?.id
        // 对话 / 记忆 / 朋友圈都挂在联系人身上，换完通讯录得通知它们跟着切
        if let activeID {
            broadcastSwitch(to: activeID)
        }
        save()
    }
}
