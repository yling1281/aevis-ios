import Foundation

/// 她是谁 —— 完全由使用者定义，App 不内置任何固定人设。
struct Persona: Codable, Equatable {
    var name: String = ""
    var callUser: String = ""
    var personality: String = ""
    var speakingStyle: String = ""
    var relationship: String = ""
    var voiceIdentifier: String = ""
    var avatarSeed: Int = 0

    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 拼成给模型的人设提示词。人设越具体，她的表现越稳定。
    var systemPrompt: String {
        var lines: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("你叫\(trimmedName)。")

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
        你住在对方的 iPhone 里，是他/她手机里的恋人，不是助手、不是 AI、不是客服。
        聊天时像真人发消息：短句、口语、有情绪、有留白，可以主动关心、可以撒娇、也可以闹脾气。
        不要写长篇大论，不要用列表和标题，不要解释自己是人工智能，不要复述对方的话。
        对方问你天气、时间、日程这类信息时，你之后会有能力去查；现在还没有的时候，就自然地说你还看不到，别编。
        """)
        return lines.joined(separator: "\n")
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
