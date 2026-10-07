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
        /// 她发来的一条**语音消息**（微信那种语音条，点一下播放）。
        /// 音频在 `voiceData`，时长在 `voiceDuration`。文字版还在对应的
        /// 那条 `.text` 里，所以这一条不进模型、也不参与去重。
        case voice
        /// ⭐ 老板 2026-10：她在**自己的小手机**上做了一件事（打开了某个 App）。
        ///
        /// 记在聊天流里，好让"我"这边看得到「她刚打开了淘宝」——
        /// 这就是老板要的"两边同步"的观感。人话写在 `text` 里、这一条**要发给模型**
        /// （她得知道自己手机上刚才做了什么），`herAppName` / `herAction` 只负责界面怎么画。
        ///
        /// ⚠️ `Kind` 是 `String` 原始值的 `Codable`：**新增 case 是安全的** ——
        ///    老存档里只有 text/call/transfer/voice 四个值，多一个 case 不影响它们解码。
        ///    （反向不成立：含 `.herPhone` 的**新存档**用**老版本** App 读会解不出来 ——
        ///     这是"新功能往前加"无法避免的，所以别改现有 4 个 case 的名字。）
        case herPhone
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
        /// ⭐ #23（2026-09-30）：TA 没肯收、钱退回来了。和「待收款」要分开显示。
        var declined: Bool = false
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

    /// 这条消息是从哪个通道传进来的。
    /// `nil` = App 里自己聊的（默认）；`"wechat"` = 微信 ClawBot 通道；`"qq"` = QQ 通道。
    /// ⚠️ 和 `imageData`/`callSeconds` 一个套路：**可选 + 有默认值** ⇒ 老存档缺这个键就是 nil，不会读崩。
    var source: String? = nil

    /// 这条消息带的一张图（已经压过的 JPEG）。
    ///
    /// **图只在这台手机上显示，不会发给模型** —— 她收到的是从图里 OCR 出来的
    /// 文字，也就是上面的 `text`。用户的原话：
    /// 「发送图片的话，走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    ///
    /// 声明成可选，所以老存档读进来也不会报错（缺这个键就是 nil）。
    var imageData: Data? = nil

    /// 她发来的语音消息的音频（mp3）。只有 `kind == .voice` 才有。
    var voiceData: Data? = nil
    /// 这条语音有多长（秒），气泡上要显示。
    var voiceDuration: Double? = nil

    /// 「小手机」那条消息用：她打开了哪个 App（用来取图标 + 写卡片文案）。
    ///
    /// ⚠️ 声明成可选并给默认值 —— 老存档里没有这个键，缺了就是 nil，
    ///    **不会读崩**（跟 `transfer` / `imageData` 一个套路）。
    var herAppName: String? = nil
    /// 「小手机」那条消息用：她的动作，如"打开了 淘宝"。
    var herAction: String? = nil

    /// ⭐ 群聊用：**这条是群里哪个成员说的**（通讯录里联系人的 id）。
    ///
    /// `nil` = 不是群聊消息 —— 一对一的「我 / ta」、或者系统消息。
    /// 有了它，界面上才能按不同的发言人画不同的头像和名字。
    ///
    /// ⚠️ 声明成可选并给默认值 —— 老存档里没有这个键，缺了就是 nil，
    ///    **不会读崩**（跟 `transfer` / `imageData` / `source` 一个套路）。
    var speakerID: UUID? = nil

    /// ⭐ 群聊用：**发言人的名字快照**。
    ///
    /// 为什么要存名字而不是只存 `speakerID`：`LLMService` 给模型拼历史时
    /// 要给每条 assistant 消息加「名字：」前缀，而它在**后台线程**跑，
    /// **不能**去读 `PersonaStore`（主线程隔离，后台读在 iOS 26 上会崩）。
    /// 所以名字在这一条落库的时候就顺手记下来，拼提示词时直接用。
    ///
    /// 名字改了不影响历史 —— 那是「当时他叫什么」，留着正好。
    /// `nil` = 非群聊消息 / 老存档。
    var speakerName: String? = nil

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
        // ⭐ 小手机那条也要发：让她"记得自己刚在手机上干了什么"，
        //   这样对话才有真实感（人话已经在 `text` 里）。
        if kind == .herPhone { return true }
        return kind == .text && !text.isEmpty
    }

    /// 「小手机」那条消息**给模型看 / 卡片显示**的那句人话。
    /// 例如 `"她打开了 淘宝"`。
    static func herPhoneLine(action: String) -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "她动了动自己的小手机。" : "她\(trimmed)。"
    }

    /// 会话列表那一行显示什么。
    /// 带图的消息显示「[图片]」—— 否则预览里会是一整段「【图片里的内容】…」。
    var previewText: String {
        if kind == .call { return text }
        if kind == .voice { return "[语音]" }
        if kind == .transfer {
            guard let info = transfer else { return text }
            let tag = info.isRedPacket ? "红包" : "转账"
            return "[\(tag) ¥\(String(format: "%.2f", info.amount))]"
        }
        // ⭐ 小手机：会话列表显示成 `[小手机] 她打开了 淘宝`。
        if kind == .herPhone {
            let action = herAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return action.isEmpty ? "[小手机]" : "[小手机] 她\(action)"
        }
        if imageData != nil { return "[图片]" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
