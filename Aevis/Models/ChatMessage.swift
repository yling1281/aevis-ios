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
        /// 转账 / 红包气泡（用户 2026-09-29 要的「假支付」，纯本地假数据）。
        /// ⚠️ 和 `.call` 不一样：**这一条要发给模型**（她得知道你给她转钱了），
        ///    所以人话写在 `text` 里，`transfer` 只负责界面怎么画。
        case transfer
    }

    /// 转账 / 红包这一条的内容。
    ///
    /// ⚠️ 声明成可选并给默认值 —— 老存档里没有这个键，缺了就是 nil，
    ///    **不会读崩**（跟 `imageData` / `callSeconds` 一个套路）。
    struct Transfer: Codable, Equatable {
        var amount: Double
        /// 转账附言（微信那个"添加转账说明"）。
        var note: String = ""
        /// 对面收下了没有。没收就一直挂着"待收款"。
        var accepted: Bool = false
        /// 红包画得喜庆一点；转账画得正经一点。
        var isRedPacket: Bool = false
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
    var kind: Kind = .text
    /// 通话记录用：这一通通了多久（秒）。
    var callSeconds: Double? = nil
    /// 转账 / 红包内容。只有 `kind == .transfer` 才有。
    var transfer: Transfer? = nil

    /// 这条消息带的一张图（已经压过的 JPEG）。
    ///
    /// **图只在这台手机上显示，不会发给模型** —— 她收到的是从图里 OCR 出来的
    /// 文字，也就是上面的 `text`。用户的原话：
    /// 「发送图片的话，走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    ///
    /// 声明成可选，所以老存档读进来也不会报错（缺这个键就是 nil）。
    var imageData: Data? = nil

    /// 转账那条消息**给模型看的那句人话**。
    ///
    /// 气泡本身是画出来的（读 `transfer`），这句话只负责两件事：
    /// 让 TA 知道"发生了什么"，以及会话列表/通知里有个能读的预览。
    static func transferLine(_ info: Transfer, mine: Bool) -> String {
        let tag = info.isRedPacket ? "红包" : "转账"
        let tail = info.note.isEmpty ? "" : "，附言：\(info.note)"
        if mine {
            return "我给 TA 发了一个\(tag) ¥\(String(format: "%.2f", info.amount))\(tail)。"
        }
        return "TA 给我发了一个\(tag) ¥\(String(format: "%.2f", info.amount))\(tail)。"
    }

    /// 该不该把这条塞进给模型的对话历史里。
    ///
    /// 通话记录是**给眼睛看的**，不是一句"人话" —— 喂给模型只会让它
    /// 学着回「通话时长 03:21」这种东西。真正聊了什么，那些文字消息一条不少，
    /// 所以模型并不会因此失忆。
    var goesToModel: Bool {
        // 转账要让她知道（「我给你转了 12 块」这种事必须进上下文）；
        // 通话记录只给眼睛看。
        if kind == .transfer { return true }
        return kind == .text && !text.isEmpty
    }

    /// 会话列表那一行显示什么。
    /// 带图的消息显示「[图片]」—— 否则预览里会是一整段「【图片里的内容】…」。
    var previewText: String {
        if kind == .call { return text }
        if kind == .transfer {
            guard let info = transfer else { return text }
            let tag = info.isRedPacket ? "红包" : "转账"
            return "[\(tag) ¥\(String(format: "%.2f", info.amount))]"
        }
        if imageData != nil { return "[图片]" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
