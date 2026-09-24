import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
}
