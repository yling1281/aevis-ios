import Foundation

/// QQ 桥接 —— 走 **OneBot 11** 那套 HTTP 接口（NapCat / LLOneBot / go-cqhttp 都兼容）。
///
/// ## 为什么是「桥接」而不是「直接连」
/// QQ 没有给第三方的 IM 接口，**App 也没法在手机上自己登 QQ** ——
/// 这不是配置问题，是能力上没有：
/// - 官方 iOS SDK 只给「登录换 openid / 分享 / 加群」，**读不到也发不出聊天消息**；
/// - 能"在设备上跑"的几个开源实现（go-cqhttp / mirai / NapCat）分别需要
///   Go + 老协议（早被腾讯封了）、JVM、或者电脑版 QQ 客户端本身；
/// - 剩下唯一的路是重新实现 QQ 的协议和签名，那是持续逆向量级的事，
///   而且腾讯一改就得跟着改 —— 不适合放进一个 App 里。
///
/// 所以通行做法是**在外面跑一个 OneBot 实现**（它负责登录），
/// 对外开一个 HTTP 端口，我们在这头调它。
///
/// ⚠️ **「外面」不等于「电脑」**。放服务器上更好：手机在任何网络下都能用，
/// 不用一直开着电脑。用户明确说过不想依赖电脑 —— 所以这里的地址是通用的，
/// 填公网地址就是"随处可用"，填 `192.168.x.x` 就是"同一个 WiFi 下可用"。
///
/// 地址留空就整块不生效，不会报错 —— 这是这个项目一贯的口径：
/// 没配的东西就该安静地不存在。
final class QQBridge {

    static let shared = QQBridge()

    private init() {}

    // MARK: - 配置

    private var settings: AppSettings { AppSettings.shared }

    var isConfigured: Bool {
        !settings.qqBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 能不能用：开关开着 + 地址填了。
    var isEnabled: Bool {
        settings.qqBridgeEnabled && isConfigured
    }

    private var base: String {
        var text = settings.qqBridgeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - 底层

    /// 调一个 OneBot 接口。
    ///
    /// 返回值是 `data` 字段（大多数接口的正文都在里面）。
    private func call(_ action: String, _ body: [String: Any] = [:]) async throws -> Any? {
        guard isConfigured else { throw QQError.notConfigured }
        guard let url = URL(string: base + "/" + action) else { throw QQError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = settings.qqBridgeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QQError.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw QQError.http(status: status,
                               body: String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QQError.badResponse(String(decoding: data.prefix(160), as: UTF8.self))
        }
        // 令牌不对时有些实现回 401，有些回一个非 0 的 retcode
        if let retcode = json["retcode"] as? Int, retcode != 0 {
            let message = (json["message"] as? String) ?? (json["wording"] as? String) ?? ""
            if retcode == 1403 || retcode == 1404 {
                throw QQError.unauthorized
            }
            throw QQError.api(code: retcode, message: message)
        }
        return json["data"]
    }

    // MARK: - 读

    /// 登录信息 —— 「测试连接」就是调它。
    struct Login: Hashable {
        var userID: String
        var nickname: String
    }

    func loginInfo() async throws -> Login {
        let data = try await call("get_login_info")
        guard let dict = data as? [String: Any] else {
            throw QQError.badResponse("没拿到登录信息")
        }
        return Login(
            userID: Self.text(dict["user_id"]),
            nickname: (dict["nickname"] as? String) ?? ""
        )
    }

    /// 好友列表。
    func friends() async throws -> [(id: String, name: String)] {
        let data = try await call("get_friend_list")
        guard let list = data as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let id = Self.text(item["user_id"])
            guard !id.isEmpty else { return nil }
            let name = (item["remark"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (item["nickname"] as? String)
                ?? id
            return (id, name)
        }
    }

    /// 群列表。
    func groups() async throws -> [(id: String, name: String)] {
        let data = try await call("get_group_list")
        guard let list = data as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let id = Self.text(item["group_id"])
            guard !id.isEmpty else { return nil }
            return (id, (item["group_name"] as? String) ?? id)
        }
    }

    /// 一条聊天记录。
    struct Line: Hashable {
        var from: String
        var text: String
        /// 秒级时间戳
        var time: Double
    }

    /// 读某个会话最近的聊天记录。
    ///
    /// `isGroup` 决定调哪个接口：群走 `get_group_msg_history`，
    /// 私聊走 `get_friend_msg_history`（NapCat / LLOneBot 都实现了这两个）。
    func history(target: String, isGroup: Bool, count: Int = 20) async throws -> [Line] {
        let action = isGroup ? "get_group_msg_history" : "get_friend_msg_history"
        let key = isGroup ? "group_id" : "user_id"
        guard let number = Int64(target) else {
            throw QQError.badResponse("「\(target)」不是个号码")
        }

        let data = try await call(action, [key: number, "count": max(1, min(count, 50))])
        // 两种返回形态：有的是 data.messages，有的直接是数组
        let messages: [[String: Any]]
        if let dict = data as? [String: Any], let list = dict["messages"] as? [[String: Any]] {
            messages = list
        } else if let list = data as? [[String: Any]] {
            messages = list
        } else {
            messages = []
        }

        return messages.map { item in
            let sender = item["sender"] as? [String: Any]
            let name = (sender?["card"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (sender?["nickname"] as? String)
                ?? Self.text(item["user_id"])
            // raw_message 更接近用户看到的样子；没有就退回 message
            let text = (item["raw_message"] as? String)
                ?? (item["message"] as? String)
                ?? ""
            return Line(from: name, text: text, time: Self.number(item["time"]))
        }
    }

    // MARK: - 写

    /// 发一条消息。
    func send(_ text: String, to target: String, isGroup: Bool) async throws {
        guard let number = Int64(target) else {
            throw QQError.badResponse("「\(target)」不是个号码")
        }
        let action = isGroup ? "send_group_msg" : "send_private_msg"
        let key = isGroup ? "group_id" : "user_id"
        _ = try await call(action, [key: number, "message": text])
    }

    // MARK: - 零件

    /// OneBot 里数字有时是 Int，有时是字符串 —— 两种都认。
    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        if let number = value as? Int64 { return String(number) }
        if let number = value as? Double { return String(Int64(number)) }
        return ""
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String, let number = Double(text) { return number }
        return 0
    }
}

enum QQError: LocalizedError {
    case notConfigured
    case badURL
    case unreachable(String)
    case http(status: Int, body: String)
    case unauthorized
    case api(code: Int, message: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填 QQ 桥接的地址。去「我 → 设置 → QQ 桥接」填上那个 OneBot 服务的地址"
                + "（放服务器上最好，手机在哪都能用）。"
        case .badURL:
            return "QQ 桥接的地址拼不出合法的网址，检查一下是不是写全了（要带 http://）。"
        case let .unreachable(reason):
            return "连不上 QQ 桥接：\(reason)。那个 OneBot 服务在跑吗？"
                + "地址填对了吗（如果是局域网地址，手机和服务要在同一个网络下）？"
        case let .http(status, body):
            return "QQ 桥接返回 HTTP \(status)：\(body.prefix(120))"
        case .unauthorized:
            return "QQ 桥接说令牌不对。去「设置 → QQ 桥接」核对一下 Access Token。"
        case let .api(code, message):
            return "QQ 桥接返回错误 \(code)\(message.isEmpty ? "" : "：\(message)")"
        case let .badResponse(text):
            return "QQ 桥接返回的内容看不懂：\(text.prefix(120))"
        }
    }
}
