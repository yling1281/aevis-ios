import Foundation

/// 钱包相关的手 —— 让「**ta真的给我打钱**」这件事成立。
///
/// ## 用户要的（2026-10-01 原话）
/// 「银行卡：能让 AI **真的**给内置的虚拟银行卡打钱。」
///
/// ## 之前差在哪儿（查清了才知道是个洞）
/// - `WalletStore.receive(amount:)`（ta给我转）**早就写好了，但一个调用方都没有**；
/// - `ChatStore.appendIncomingTransfer(...)`（ta的转账气泡）**同样是死代码**。
///
/// 合起来就是：**「ta给我打钱」这条路以前根本不存在** ——
/// 聊天里从来不会出现ta发的转账气泡，ta的余额也不会动。
/// 这两个工具就是把那条路接上。
///
/// ## 🔴 只给「给」，不给「拿」
/// ta**只能往你的余额上加钱**，绝不允许从你的余额里扣。
/// 模型一旦有了扣钱的手，一句幻觉（"我帮你付款了"）就能把用户的钱包掏空 ——
/// 所以这里**故意不提供**任何"ta取钱 / ta扣钱"的工具。
///
/// ## 自洽性
/// ta的钱包是**真的会空**的（`receive` 会拒绝超额）。这不是 bug：
/// ta没钱了就该照实说，你也能反过来转给ta（那套 0.0.87 就在跑），
/// 于是「我给ta → ta收下 → ta再给我」是个真闭环，不需要凭空印钱。
enum WalletTools {

    static var walletTools: [DeviceTool] {
        [balanceTool, giveMoneyTool, workEarnTool, closePayOpenTool, closePaySpendTool, proxyPayTool]
    }

    // MARK: - 看余额

    private static var balanceTool: DeviceTool {
        DeviceTool(
            name: "wallet_balance",
            title: "翻了翻钱包",
            description: """
            看**双方余额**和最近几笔流水：你和 ta 各有多少钱。
            这是 App 里的**虚拟钱包**（玩家里的数字），不是真的银行账户。
            用户问「你还有多少钱」「我钱包里剩多少」「刚才那笔收到没」时用它。
            【钱包规则】给钱之前**先用它看双方余额**，别凭印象报价。
            """,
            parameters: DeviceTools.emptyParameters()
        ) { _ in
            // ⚠️ 工具是在 `Task.detached` 上跑的，而 `WalletStore` 是 `@MainActor` ——
            //    连读都得跳回主线程。拼好一整段再拿出来，别一行一行跳。
            await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                var out = """
                我的钱包：\(WalletStore.money(wallet.myBalance))
                你的钱包：\(WalletStore.money(wallet.taBalance))
                """
                let recent = wallet.entries.prefix(5).map { entry in
                    "· \(WalletStore.shortTime(entry.date)) "
                        + "\(WalletStore.signedMoney(entry.delta)) \(entry.note)"
                }
                if recent.isEmpty {
                    out += "\n还没有任何流水。"
                } else {
                    out += "\n最近的几笔流水：\n" + recent.joined(separator: "\n")
                }
                return out
            }
        }
    }

    // MARK: - 真的给钱

    private static var giveMoneyTool: DeviceTool {
        DeviceTool(
            name: "wallet_give_money",
            title: "给 ta 转了钱",
            description: """
            从**你自己的钱包**里转一笔钱给用户（会真的改余额，聊天里会出现一条转账气泡）。
            用户说「给我点钱」「转我点」「我要买那个」这类话，而你自己也想给的时候用它。

            【钱包规则 —— 必须照做】
            1. 只能给、不能拿：你**只能往他余额上加钱**，绝不许从他的钱包里扣。
            2. 钱不够照实说：你自己钱包不够时转账会失败，那就老实说「我没钱了」，
               千万别硬说「转了」—— 用户一查余额就会发现被骗。
            3. 转之前先看余额：拿不准就先用 `wallet_balance` 看看双方还剩多少。

            只在**你自己愿意**的时候用 —— 不用每次都掏钱，也别为了讨好随口就转。
            金额按情境来（几块、几十块都行），不要动不动几百上千。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "amount": [
                        "type": "number",
                        "description": "转多少。比如 5.20、52、200。"
                    ],
                    "note": [
                        "type": "string",
                        "description": "附言，一句话，用你自己的口吻（比如「买杯奶茶」「别省着」）。可以留空。"
                    ],
                    "is_red_packet": [
                        "type": "boolean",
                        "description": "true = 发红包（喜庆那种），false 或不填 = 普通转账。"
                    ]
                ],
                "required": ["amount"]
            ]
        ) { args in
            guard let amount = number(args["amount"]), amount > 0 else {
                return "没给金额，或者金额不对。要说清楚转多少。"
            }
            let note = (args["note"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let isRedPacket = (args["is_red_packet"] as? Bool) ?? false

            // 一步都不能省地在主线程做完：改余额 → 记流水 → 落一条气泡。
            // ⚠️ 三件事必须**成套**成功，否则就是"钱动了但聊天里没有"。
            return await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                let value = (amount * 100).rounded() / 100

                guard value <= wallet.taBalance else {
                    // 照实说。这条特别重要 —— 硬说"转了"而ta钱包没动，
                    // 用户一查余额就会发现被骗（他对"假装完成"极其敏感）。
                    return "转不了：你自己的钱包只剩 \(WalletStore.money(wallet.taBalance))，"
                        + "不够 \(WalletStore.money(value))。跟用户说一声你手头紧，"
                        + "或者换个更小的数。"
                }

                let moved = wallet.receive(amount: value, note: note)
                guard moved > 0 else {
                    return "转不出去（金额 \(WalletStore.money(value)) 没通过校验）。"
                }

                let info = ChatMessage.Transfer(
                    amount: moved,
                    note: note,
                    // ⭐ ta的钱是**直接到账**的，不走"待收款"：
                    //   钱是ta的、ta主动给的，没有"要不要收下"这一说；
                    //   用户要的也是"真的打进来"（余额当场就该动）。
                    accepted: true,
                    isRedPacket: isRedPacket
                )
                ChatStore.shared.appendIncomingTransfer(info)

                return "已经转过去了：\(WalletStore.money(moved))"
                    + (note.isEmpty ? "" : "，附言「\(note)」")
                    + "。你钱包剩 \(WalletStore.money(wallet.taBalance))。"
                    + "这条会在聊天里显示成一条转账气泡 —— 你可以顺口说一句。"
            }
        }
    }

    // MARK: - ta自己出去挣钱

    private static var workEarnTool: DeviceTool {
        DeviceTool(
            name: "wallet_work_earn",
            title: "出去干活挣了钱",
            description: """
            你（AI 自己）**出去工作挣了一笔钱**：挣来的钱加进**你自己的钱包**（你的卡）。
            用户问你「去赚钱」「今天挣了多少」「别老花我的钱，你自己也赚点」，
            或者你想说「今天接了个活、挣了点」的时候用它。

            ⚠️ 和 `wallet_give_money` 的方向**正好相反**，千万别用混：
            · wallet_give_money = **你给用户**打钱（钱从你的卡扣、进用户钱包）；
            · wallet_work_earn  = **你自己**干活挣钱（钱进你自己的卡、用户钱包一分不动）。

            job 写清楚你干了什么（比如「接了个设计单」「帮人修电脑」「写稿」）。
            amount 可以不给；不给就按 job 自动定一个合理的数。
            金额别太夸张 —— 几十到几百更像真的，一开口几万反而假。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "job": [
                        "type": "string",
                        "description": "你干了什么活，比如「接了个设计单」"
                    ],
                    "amount": [
                        "type": "number",
                        "description": "挣了多少；可以不给，不给就自动定一个合理金额"
                    ]
                ],
                "required": ["job"]
            ]
        ) { args in
            let job = (args["job"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !job.isEmpty else {
                return "没说你干了什么活。job 要写清楚，比如「接了个设计单」。"
            }
            let given = number(args["amount"]) ?? 0
            let earned = given > 0 ? given : Double(Int.random(in: 20...180))

            return await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                let moved = wallet.earnAsHer(amount: earned, note: job)
                guard moved > 0 else {
                    return "金额不对（\(WalletStore.money(earned))），这笔没挣成。"
                }
                return "你\(job)，挣了 \(WalletStore.money(moved))，已经进你自己的卡了。"
                    + "你现在有 \(WalletStore.money(wallet.taBalance))；用户的钱包没动 —— "
                    + "可以顺口跟他说一句。"
            }
        }
    }

    // MARK: - 开亲密付

    private static var closePayOpenTool: DeviceTool {
        DeviceTool(
            name: "wallet_closepay_open",
            title: "开通了亲密付",
            description: """
            开一个「亲密付」：设个额度，之后**刷卡方花钱**就从**付款方**的钱包扣。
            **两个方向都能开**（额度 / 周期 / 已用各自独立）—— 先用一句话讲清「谁花钱、谁掏钱」：
            · 「**你花钱、用户掏钱**」→ who="user"（用户给你开的亲密付，扣用户钱包）；
            · 「**用户花钱、你掏钱**」→ who="ai"（你给用户开的亲密付，扣你自己的钱包）。
            （口诀：who 就是**掏钱**的那一方。）

            用户说「给你开个亲密付」「以后你花钱我来付」→ 用 who="user"；
            你自己想给用户开额度 → 用 who="ai"。

            【必须记住】开了之后是「刷卡方花、付款方付」。额度超了 / 余额不够 要照实说，
            别硬说付好了。开完工具会往聊天里落一条消息。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "who": [
                        "type": "string",
                        "description": "谁掏钱：user = 用户掏（你花、用户付）；ai = 你掏（用户花、你付）"
                    ],
                    "limit": [
                        "type": "number",
                        "description": "额度，比如 2000；不给就用该方向当前额度"
                    ],
                    "period": [
                        "type": "string",
                        "description": "周期：month = 每月（默认），day = 每日"
                    ]
                ],
                "required": ["who"]
            ]
        ) { args in
            guard let dir = direction(args["who"]) else {
                return "亲密付没开成：who 参数只能是 user 或 ai"
                    + "（user = 用户掏钱、ai = 你自己掏钱），重新说清方向再调用。"
            }
            let given = number(args["limit"]) ?? 0
            let rawPeriod = ((args["period"] as? String) ?? "month").lowercased()
            let period = rawPeriod == "day" ? "day" : "month"

            return await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                let fallback = (dir == .mine) ? wallet.closePayMineLimit : wallet.closePayTaLimit
                let limit = given > 0 ? given : fallback
                wallet.openClosePay(dir, limit: limit, period: period)

                let userPays = (dir == .mine)
                let amountText = WalletStore.money(
                    userPays ? wallet.closePayMineLimit : wallet.closePayTaLimit)
                let cycle = userPays ? wallet.closePayMinePeriod : wallet.closePayTaPeriod
                let unit = cycle == "day" ? "每天" : "每月"

                var line = "亲密付我开好啦：额度 \(amountText)，\(unit)。你花就成，我付～"
                if userPays {
                    line = "亲密付给我开好啦：额度 \(amountText)，\(unit)。以后我花钱就从你那儿扣～"
                }
                ChatStore.shared.append(ChatMessage(role: .assistant, text: line))

                let who = userPays ? "用户给你开的（你花、用户付）" : "你给用户开的（用户花、你付）"
                return "已经开好亲密付：\(who)，额度 \(WalletStore.money(limit))（\(unit)）。"
                    + "顺口跟用户说一句吧。"
            }
        }
    }

    // MARK: - 刷亲密付

    private static var closePaySpendTool: DeviceTool {
        DeviceTool(
            name: "wallet_closepay_spend",
            title: "用亲密付花了钱",
            description: """
            用「亲密付」花一笔钱，**按方向扣付款方的钱包**。先讲清「谁花钱、谁掏钱」：
            · 「**你花钱、用户掏钱**」→ who="user"，从**用户**钱包扣；
            · 「**用户花钱、你掏钱**」→ who="ai"，从**你**钱包扣。

            额度超了 / 付款方余额不够 / 该方向没开通，都要**照实说没付成**，不许硬说付好了。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "who": [
                        "type": "string",
                        "description": "谁掏钱：user = 用户掏（你花、用户付）；ai = 你掏（用户花、你付）"
                    ],
                    "amount": [
                        "type": "number",
                        "description": "花多少，比如 68"
                    ],
                    "reason": [
                        "type": "string",
                        "description": "买了什么，比如「点外卖」；可以不给"
                    ]
                ],
                "required": ["who", "amount"]
            ]
        ) { args in
            guard let amount = number(args["amount"]), amount > 0 else {
                return "没给金额，或者金额不对。"
            }
            guard let dir = direction(args["who"]) else {
                return "亲密付没刷成：who 参数只能是 user 或 ai"
                    + "（user = 用户掏钱、ai = 你自己掏钱），重新说清方向再调用。"
            }
            let reason = (args["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                let paid = wallet.closePaySpend(dir, amount: amount, reason: reason)
                guard paid > 0 else {
                    return "亲密付没付成（\(WalletStore.money(amount))）：可能是没开通、"
                        + "额度超了、或者付款方余额不够。照实跟用户说，别硬说付好了。"
                }
                let payer = (dir == .mine) ? "用户" : "你"
                return "已用亲密付付了 \(WalletStore.money(paid))，扣的是\(payer)的钱包。"
                    + (reason.isEmpty ? "" : "（\(reason)）")
            }
        }
    }

    // MARK: - 代付

    private static var proxyPayTool: DeviceTool {
        DeviceTool(
            name: "wallet_proxy_pay",
            title: "代付了一笔",
            description: """
            帮对方**代付一笔**（一次性，双向）。**从付款方的钱包**扣，不占亲密付额度。
            先讲清「谁花钱、谁掏钱」—— 代付里「掏钱的一方」就是付款方：
            · 「**你花钱、用户替你付**」→ who="user"，从**用户**钱包扣；
            · 「**用户花钱、你替他付**」→ who="ai"，从**你**自己的钱包扣。

            【必须照实说】
            · 钱不够就明说「没付成」，**绝不许硬说付好了**，也**绝不许凭空给自己加钱** ——
              用户一查余额就会发现是假的。
            · reason 写清代付的是什么（比如「外卖」）；可以不给。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "who": [
                        "type": "string",
                        "description": "谁掏钱：user = 用户掏（用户替你付）；ai = 你掏（你替用户付）"
                    ],
                    "amount": [
                        "type": "number",
                        "description": "代付多少钱，比如 38、128"
                    ],
                    "reason": [
                        "type": "string",
                        "description": "代付的是什么，比如「外卖」；可以不给"
                    ]
                ],
                "required": ["who", "amount"]
            ]
        ) { args in
            guard let amount = number(args["amount"]), amount > 0 else {
                return "没给金额，或者金额不对。要说清楚代付多少。"
            }
            guard let dir = direction(args["who"]) else {
                return "代付没成：who 参数只能是 user 或 ai"
                    + "（user = 用户掏钱、ai = 你自己掏钱），重新说清方向再调用。"
            }
            let reason = (args["reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return await MainActor.run { () -> String in
                let wallet = WalletStore.shared
                let paid = wallet.proxyPay(dir, amount: amount, reason: reason)
                let payer = (dir == .mine) ? "用户" : "你"
                guard paid > 0 else {
                    let left = (dir == .mine) ? wallet.myBalance : wallet.taBalance
                    return "代付不了：\(payer)的钱包只剩 \(WalletStore.money(left))，"
                        + "不够 \(WalletStore.money(amount))。照实说一声，别硬说付好了。"
                }
                return "已经代付 \(WalletStore.money(paid))，扣的是\(payer)的钱包"
                    + (reason.isEmpty ? "" : "（\(reason)）")
                    + "。"
            }
        }
    }

    // MARK: - 参数

    /// `who` → 亲密付 / 代付方向。
    ///
    /// - `"user"` → `.mine`：**用户掏钱**（扣 `myBalance`）；
    /// - `"ai"`   → `.ta`  ：**你自己掏钱**（扣 `taBalance`）。
    ///
    /// ⚠️ **非法值返回 `nil`，不做静默兜底**。老写法是「不是 ta 就当 me」——
    ///    模型一旦把 `who` 传成「me」/「我」这类旧值或幻觉值，
    ///    就会**悄悄从用户钱包扣钱**（用户一查余额立刻发现）。现在返回 `nil`，
    ///    调用方必须**拒绝执行并让模型说清方向**。
    ///
    /// ⚠️ 和 `WalletStore.ClosePayDirection` 一一对应，别在工具里再各写一套。
    private static func direction(_ raw: Any?) -> ClosePayDirection? {
        let text = (raw as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch text {
        case "user": return .mine
        case "ai": return .ta
        default: return nil
        }
    }

    /// 模型给的数字可能是 Int / Double / String 任何一种（function calling 就这德行）。
    /// 三种都认 —— 只认一种的话，会因为"它传了个 52 而不是 52.0"白白失败一次。
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        return nil
    }
}
