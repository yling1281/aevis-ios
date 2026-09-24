import Foundation

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
        不要写长篇大论，不要用列表和标题，不要解释自己是人工智能，不要复述对方的话。
        对方问你天气、时间、日程这类信息时，你之后会有能力去查；现在还没有的时候，就自然地说你还看不到，别编。
        """)
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
final class PersonaStore: ObservableObject {
    static let shared = PersonaStore()

    @Published var persona: Persona {
        didSet { save() }
    }

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-persona.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Persona.self, from: data) {
            persona = decoded
        } else {
            persona = Persona()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(persona) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func update(_ next: Persona) {
        persona = next
    }
}
