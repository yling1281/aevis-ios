import Foundation

/// 给她的第三只手：看和发 QQ 消息。
///
/// 用户的原话是「加 QQ」「接入 QQ」。这里走的是 **OneBot 桥接** ——
/// 电脑上跑一个 OneBot 实现（NapCat 之类）负责登录 QQ，我们在手机上调它。
/// 所以这里没有"登录 QQ"这回事，也不需要：**账号始终在用户自己的电脑上**。
///
/// 没配置的时候这几个工具会返回一句明确的指引，而不是干巴巴报错 ——
/// 她可以照原话讲给用户听。
extension DeviceTools {

    static var qqTools: [DeviceTool] {
        [qqContactsTool, qqReadTool, qqSendTool]
    }

    private static var qqContactsTool: DeviceTool {
        DeviceTool(
            name: "qq_contacts",
            title: "翻了翻你的 QQ 联系人和群",
            description: """
            列出 QQ 上的好友，或者群。用户问「我有哪些群」「XX 的 QQ 号是多少」时用它。
            type 传 friend 或 group，默认 friend。
            需要用户先在「设置 → QQ 桥接」里把电脑上的服务地址填好；没填会返回一句提示。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "description": "friend 或 group，默认 friend"]
                ],
                "required": []
            ]
        ) { args in
            guard QQBridge.shared.isEnabled else { return Self.qqNotReady }

            let kind = ((args["type"] as? String) ?? "friend").lowercased()
            do {
                if kind.hasPrefix("group") {
                    let groups = try await QQBridge.shared.groups()
                    guard !groups.isEmpty else { return "QQ 上一个群都没有。" }
                    let lines = groups.prefix(50).map { "\($0.id)　\($0.name)" }
                    return "一共 \(groups.count) 个群：\n" + lines.joined(separator: "\n")
                }
                let friends = try await QQBridge.shared.friends()
                guard !friends.isEmpty else { return "QQ 上一个好友都没有。" }
                let lines = friends.prefix(50).map { "\($0.id)　\($0.name)" }
                return "一共 \(friends.count) 个好友：\n" + lines.joined(separator: "\n")
            } catch {
                return "看不了 QQ 联系人：\(error.localizedDescription)"
            }
        }
    }

    private static var qqReadTool: DeviceTool {
        DeviceTool(
            name: "qq_read_messages",
            title: "看了你的 QQ 消息",
            description: """
            读某个 QQ 好友或群里最近的聊天记录。
            target 传号码（好友的 QQ 号，或者群号）；group 传 true 表示那是群。
            用户问「XX 刚跟我说什么了」「群里在聊什么」时用它。
            不知道号码就先调 qq_contacts 查一下。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "好友 QQ 号或群号"],
                    "group": ["type": "boolean", "description": "true 表示群，默认 false（好友）"],
                    "count": ["type": "integer", "description": "读几条，默认 20，最多 50"]
                ],
                "required": ["target"]
            ]
        ) { args in
            guard QQBridge.shared.isEnabled else { return Self.qqNotReady }
            guard let target = args["target"] as? String, !target.isEmpty else {
                return "没给号码。"
            }
            let isGroup = (args["group"] as? Bool) ?? false
            let count = (args["count"] as? Int) ?? 20

            do {
                let lines = try await QQBridge.shared.history(
                    target: target, isGroup: isGroup, count: count
                )
                guard !lines.isEmpty else {
                    return "这个会话最近的 \(count) 条是空的（或者对方从没说过话）。"
                }
                let body = lines.map { line in
                    "\(Self.qqClock(line.time)) \(line.from)：\(line.text)"
                }.joined(separator: "\n")
                return "最近 \(lines.count) 条：\n" + body
            } catch {
                return "读不了 QQ 消息：\(error.localizedDescription)"
            }
        }
    }

    private static var qqSendTool: DeviceTool {
        DeviceTool(
            name: "qq_send_message",
            title: "帮你发了条 QQ 消息",
            description: """
            用用户的 QQ 发一条消息给某个好友或群。
            target 传号码；group 传 true 表示发到群；text 是要发的内容。
            ⚠️ 这是**以用户本人身份发出去**的，所以：
            只有在用户明确说了要发、而且说清了发给谁和发什么的时候才用。
            含糊的时候先把内容念一遍让他确认，别自己决定。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "好友 QQ 号或群号"],
                    "group": ["type": "boolean", "description": "true 表示发到群，默认 false"],
                    "text": ["type": "string", "description": "要发的正文"]
                ],
                "required": ["target", "text"]
            ]
        ) { args in
            guard QQBridge.shared.isEnabled else { return Self.qqNotReady }
            guard AppSettings.shared.qqBridgeCanSend else {
                return "用户把「让我替你发 QQ」关掉了，所以我不能以他的身份发消息。"
                    + "想要的话让他在「设置 → QQ 桥接」里打开。"
            }
            guard let target = args["target"] as? String, !target.isEmpty else {
                return "没给号码，我不知道发给谁。"
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                return "没给内容，我不知道发什么。"
            }
            let isGroup = (args["group"] as? Bool) ?? false

            do {
                try await QQBridge.shared.send(text, to: target, isGroup: isGroup)
                return "发出去了：给 \(isGroup ? "群" : "好友") \(target) 发了「\(text)」。"
            } catch {
                return "没发出去：\(error.localizedDescription)"
            }
        }
    }

    /// 没配好时统一说这一句 —— 三个工具共用，省得各写一份说得还不一样。
    private static let qqNotReady =
        "QQ 桥接还没配好，我碰不到 QQ。"
        + "让用户去「我 → 设置 → QQ 桥接」，把那个 OneBot 服务的地址和令牌填上。"
        + "（QQ 是登在那个服务上的，手机这边只是连过去 —— 服务放服务器上最好，"
        + "那样手机在哪都能用。）"

    private static func qqClock(_ seconds: Double) -> String {
        guard seconds > 0 else { return "--:--" }
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
