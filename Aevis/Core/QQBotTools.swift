import Foundation

/// 给她的第四只手：看 QQ 上发生了什么，必要时主动说一句。
///
/// ⚠️ 这一组和 `QQTools`（OneBot 桥接那组）**不是一回事**：
/// - `QQTools` 连的是**外面跑的 OneBot 服务**，能读他自己账号的好友和群
/// - 这一组走的是**官方机器人**：她在 QQ 上是一个独立的号，只能看到别人发给它的
///
/// 两条可以同时开着，互不干扰。
extension DeviceTools {

    static var qqBotTools: [DeviceTool] {
        [qqBotRecentTool, qqBotSendTool]
    }

    private static var qqBotRecentTool: DeviceTool {
        DeviceTool(
            name: "qq_bot_recent",
            title: "看了 QQ 机器人上最近的消息",
            description: """
            看 QQ 机器人这边最近收到和发出的消息（新的在前），带发送者的 openid。
            用户问「QQ 上有没有人找我」「刚刚那个人说什么了」时用它。
            想主动发消息给某个人，也先用它拿到对方的 openid。
            没开或没连上会返回一句说明。
            """,
            parameters: ["type": "object", "properties": [:], "required": []]
        ) { _ in
            guard AppSettings.shared.qqBotEnabled else {
                return "QQ 机器人没开。让用户去「我 → 设置 → QQ 机器人」把开关打开。"
            }
            // 一次性把拼好的文字取出来 —— 不在这里反复取属性，
            // 那些 `await` 放进字符串插值里最容易出岔子。
            return QQBotService.shared.recentForTools()
        }
    }

    private static var qqBotSendTool: DeviceTool {
        DeviceTool(
            name: "qq_bot_send",
            title: "在 QQ 上主动说了一句",
            description: """
            用 QQ 机器人给某个人（或某个群）主动发一条消息。
            target 填对方的 openid（先调 qq_bot_recent 拿），group 传 true 表示那是群。
            ⚠️ 平台的规矩：**主动消息通常没有权限**，只有「回复别人刚发来的消息」才一定成。
            所以这条多半会失败 —— 失败了就如实讲给用户听，别硬说发出去了。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "对方 openid 或群 openid"],
                    "text": ["type": "string", "description": "要发的内容"],
                    "group": ["type": "boolean", "description": "true 表示发给群，默认 false"]
                ],
                "required": ["target", "text"]
            ]
        ) { args in
            guard AppSettings.shared.qqBotEnabled else {
                return "QQ 机器人没开，我发不了。让用户去「我 → 设置 → QQ 机器人」打开。"
            }
            guard let target = args["target"] as? String, !target.isEmpty,
                  let text = args["text"] as? String, !text.isEmpty else {
                return "得给我「发给谁」和「发什么」。"
            }
            let isGroup = (args["group"] as? Bool) ?? false

            do {
                try await QQBotClient.shared.send(
                    scope: isGroup ? "group" : "c2c",
                    target: target,
                    content: text,
                    msgID: nil,          // 不带 msg_id = 主动消息
                    msgSeq: 1
                )
                return "发出去了：给 \(isGroup ? "群" : "对方") \(target) 发了「\(text)」。"
            } catch {
                return "没发出去：" + error.localizedDescription
            }
        }
    }
}
