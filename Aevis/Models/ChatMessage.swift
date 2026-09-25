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

    /// 这条消息带的一张图（已经压过的 JPEG）。
    ///
    /// **图只在这台手机上显示，不会发给模型** —— 她收到的是从图里 OCR 出来的
    /// 文字，也就是上面的 `text`。用户的原话：
    /// 「发送图片的话，走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    ///
    /// 声明成可选，所以老存档读进来也不会报错（缺这个键就是 nil）。
    var imageData: Data? = nil

    /// 会话列表那一行显示什么。
    /// 带图的消息显示「[图片]」—— 否则预览里会是一整段「【图片里的内容】…」。
    var previewText: String {
        if imageData != nil { return "[图片]" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
