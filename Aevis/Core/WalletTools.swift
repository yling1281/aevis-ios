import Foundation

/// 钱包相关的手 —— 让「**她真的给我打钱**」这件事成立。
///
/// ## 用户要的（2026-10-01 原话）
/// 「银行卡：能让 AI **真的**给内置的虚拟银行卡打钱。」
///
/// ## 之前差在哪儿（查清了才知道是个洞）
/// - `WalletStore.receive(amount:)`（她给我转）**早就写好了，但一个调用方都没有**；
/// - `ChatStore.appendIncomingTransfer(...)`（她的转账气泡）**同样是死代码**。
///
/// 合起来就是：**「她给我打钱」这条路以前根本不存在** ——
/// 聊天里从来不会出现她发的转账气泡，她的余额也不会动。
/// 这两个工具就是把那条路接上。
///
/// ## 🔴 只给「给」，不给「拿」
/// 她**只能往你的余额上加钱**，绝不允许从你的余额里扣。
/// 模型一旦有了扣钱的手，一句幻觉（"我帮你付款了"）就能把用户的钱包掏空 ——
/// 所以这里**故意不提供**任何"她取钱 / 她扣钱"的工具。
///
/// ## 自洽性
/// 她的钱包是**真的会空**的（`receive` 会拒绝超额）。这不是 bug：
/// 她没钱了就该照实说，你也能反过来转给她（那套 0.0.87 就在跑），
/// 于是「我给她 → 她收下 → 她再给我」是个真闭环，不需要凭空印钱。
enum WalletTools {

    static var walletTools: [DeviceTool] { [balanceTool, giveMoneyTool] }

    // MARK: - 看余额

    private static var balanceTool: DeviceTool {
        DeviceTool(
            name: "wallet_balance",
            title: "翻了翻钱包",
            description: """
            看你和 TA 各有多少钱，以及最近几笔流水。
            这是 App 里的**虚拟钱包**（玩家里的数字），不是真的银行账户。
            用户问「你还有多少钱」「我钱包里剩多少」「刚才那笔收到没」时用它。
            你也可以用来自查：给钱之前先看看自己够不够。
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
                    out += "\n你的最近几笔收支：\n" + recent.joined(separator: "\n")
                }
                return out
            }
        }
    }

    // MARK: - 真的给钱

    private static var giveMoneyTool: DeviceTool {
        DeviceTool(
            name: "wallet_give_money",
            title: "给 TA 转了钱",
            description: """
            从**你自己的钱包**里转一笔钱给用户（会真的改余额，聊天里会出现一条转账气泡）。
            用户说「给我点钱」「转我点」「我要买那个」这类话，而你自己也想给的时候用它。

            只在**你自己愿意**的时候用 —— 不用每次都掏钱，也别为了讨好随口就转。
            金额按情境来（几块、几十块都行），不要动不动几百上千。

            ⚠️ 你不能从用户的钱包里拿钱，只能给。
            ⚠️ 你自己钱包不够的时候会失败，那就照实说你没钱了，别硬说转了。
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
                    // 照实说。这条特别重要 —— 硬说"转了"而她钱包没动，
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
                    // ⭐ 她的钱是**直接到账**的，不走"待收款"：
                    //   钱是她的、她主动给的，没有"要不要收下"这一说；
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

    // MARK: - 参数

    /// 模型给的数字可能是 Int / Double / String 任何一种（function calling 就这德行）。
    /// 三种都认 —— 只认一种的话，会因为"它传了个 52 而不是 52.0"白白失败一次。
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String, let parsed = Double(text) { return parsed }
        return nil
    }
}
