import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    /// 这条消息是什么。
    ///
    /// 加这个字段是为了**通话记录**（微信那种「通话时长 03:21」）——
    /// 用户 2026-09-26 要的：「挂断电话的时候……像微信一样留下记录」。
    /// 给它一个默认值，所以**老存档读进来不会报错**（缺这个键就是 `.text`）。
    enum Kind: String, Codable {
        case text
        /// 一通电话留下的记录。**不发给模型** —— 它只是给人看的。
        case call
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
    var kind: Kind = .text
    /// 通话记录用：这一通通了多久（秒）。
    var callSeconds: Double? = nil

    /// 这条消息带的一张图（已经压过的 JPEG）。
    ///
    /// **图只在这台手机上显示，不会发给模型** —— 她收到的是从图里 OCR 出来的
    /// 文字，也就是上面的 `text`。用户的原话：
    /// 「发送图片的话，走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    ///
    /// 声明成可选，所以老存档读进来也不会报错（缺这个键就是 nil）。
    var imageData: Data? = nil

    /// 该不该把这条塞进给模型的对话历史里。
    ///
    /// 通话记录是**给眼睛看的**，不是一句"人话" —— 喂给模型只会让它
    /// 学着回「通话时长 03:21」这种东西。真正聊了什么，那些文字消息一条不少，
    /// 所以模型并不会因此失忆。
    var goesToModel: Bool {
        kind == .text && !text.isEmpty
    }

    /// 会话列表那一行显示什么。
    /// 带图的消息显示「[图片]」—— 否则预览里会是一整段「【图片里的内容】…」。
    var previewText: String {
        if kind == .call { return text }
        if imageData != nil { return "[图片]" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
