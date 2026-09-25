import Foundation

/// QQ 官方机器人（QQ 开放平台）的底层客户端。
///
/// ## 为什么这条路能「在手机上、不用电脑、不用服务器」
/// 官方机器人是**平台替你登录**的：你拿 AppID + AppSecret 换一个 access_token，
/// 然后走 HTTPS 发消息、走 WebSocket 收消息。**全程只是一个普通的网络客户端** ——
/// 不需要 Node / .NET / JVM，不需要模拟 QQ 客户端，也不需要任何一台常开的机器。
///
/// 对比一下为什么别的路都不行（这些结论都验过）：
/// - NapCat / LLOneBot 要**桌面版 QQ 客户端**（Electron），手机里跑不了
/// - Lagrange 要 .NET 运行时，go-cqhttp 那套协议**早被腾讯封了**
/// - 自己实现 QQ 协议？那是持续逆向量级的事
///
/// ## 协议细节的来源（不是我猜的）
/// 官方插件 `tencent-connect/openclaw-qqbot` 底层用的是 SDK
/// `@tencent-connect/qqbot-nodejs`。下面这些常量都是从那个 SDK 的源码里抄出来的：
/// - 换 token：`POST https://bots.qq.com/app/getAppAccessToken`
/// - 业务接口：`https://api.sgroup.qq.com`
/// - 鉴权头：`Authorization: QQBot <access_token>`
/// - 取网关：`GET /gateway`；发消息：`POST /v2/users/{openid}/messages`
///   （群是 `/v2/groups/{group_openid}/messages`）
/// - 消息体：`{content, msg_type: 0, msg_seq: N}`，被动回复再带 `msg_id`
final class QQBotClient {

    static let shared = QQBotClient()

    private let tokenURL = "https://bots.qq.com/app/getAppAccessToken"
    private let apiBase = "https://api.sgroup.qq.com"

    /// access_token 的缓存。一个 AppID 一份，提前 5 分钟就换新的。
    private var cachedToken: String?
    private var tokenExpiresAt = Date.distantPast
    private let lock = NSLock()

    private init() {}

    // MARK: - 凭据

    struct Credentials {
        var appID: String
        var secret: String
        /// 沙箱环境用另一套（这里只影响提示文案，域名是同一个）。
        var sandbox: Bool
    }

    var credentials: Credentials {
        Credentials(
            appID: AppSettings.shared.qqBotAppID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: AppSettings.shared.qqBotSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            sandbox: AppSettings.shared.qqBotSandbox
        )
    }

    var isConfigured: Bool {
        let creds = credentials
        return !creds.appID.isEmpty && !creds.secret.isEmpty
    }

    // MARK: - 换 token

    /// 拿 access_token。**缓存一份**，提前 5 分钟过期 —— 每次发消息都换一次会被限流。
    func accessToken(force: Bool = false) async throws -> String {
        lock.lock()
        if !force, let token = cachedToken, Date() < tokenExpiresAt {
            lock.unlock()
            return token
        }
        lock.unlock()

        let creds = credentials
        guard !creds.appID.isEmpty, !creds.secret.isEmpty else {
            throw QQBotError.notConfigured
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "appId": creds.appID,
            "clientSecret": creds.secret
        ])

        let json = try await send(request, label: "换 token")
        guard let token = json["access_token"] as? String, !token.isEmpty else {
            throw QQBotError.badResponse("换 token 的返回里没有 access_token")
        }
        // expires_in 有时是字符串、有时是数字，两种都认
        let expires = Self.number(json["expires_in"]) ?? 7200
        lock.lock()
        cachedToken = token
        tokenExpiresAt = Date().addingTimeInterval(max(60, expires - 300))
        lock.unlock()
        return token
    }

    func forgetToken() {
        lock.lock()
        cachedToken = nil
        tokenExpiresAt = .distantPast
        lock.unlock()
    }

    // MARK: - 业务接口

    /// 取 WebSocket 网关地址。
    func gatewayURL() async throws -> URL {
        let json = try await call("GET", "/gateway")
        guard let text = json["url"] as? String, let url = URL(string: text) else {
            throw QQBotError.badResponse("网关地址没给对")
        }
        return url
    }

    /// 机器人自己的信息 —— 「测试连接」就是调它。
    struct BotInfo {
        var name: String
        var id: String
    }

    func me() async throws -> BotInfo {
        let json = try await call("GET", "/users/@me")
        return BotInfo(
            name: (json["username"] as? String) ?? "QQ 机器人",
            id: (json["id"] as? String) ?? ""
        )
    }

    /// 发一条消息。
    ///
    /// - Parameters:
    ///   - scope: `c2c` 是私聊，`group` 是群
    ///   - target: 私聊填 `user_openid`，群填 `group_openid`
    ///   - msgID: **被动回复必须带**（就是收到的那条消息的 id）。
    ///            不带就是主动消息，需要平台单独开通权限，会直接被拒。
    ///   - msgSeq: 对同一条消息的第几次回复。同一个 msg_id 最多回 5 次，
    ///             所以每回一次要 +1。
    @discardableResult
    func send(scope: String, target: String, content: String, msgID: String?, msgSeq: Int) async throws -> [String: Any] {
        let path = scope == "c2c" ? "/v2/users/\(target)/messages" : "/v2/groups/\(target)/messages"
        var body: [String: Any] = [
            "content": content,
            "msg_type": 0,
            "msg_seq": msgSeq
        ]
        if let msgID, !msgID.isEmpty { body["msg_id"] = msgID }
        return try await call("POST", path, body: body)
    }

    // MARK: - 底层

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard isConfigured else { throw QQBotError.notConfigured }
        let token = try await accessToken()

        guard let url = URL(string: apiBase + path) else {
            throw QQBotError.badResponse("路径拼错了：\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("QQBot \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let json = try await send(request, label: path)
        // 腾讯的错误体是 {message, code}；把原话带出去，比"失败了"有用得多
        if let code = json["code"] as? Int, code != 0 {
            let message = (json["message"] as? String) ?? ""
            // token 过期就清掉缓存，下次自动换新的
            if code == 11244 || code == 11253 || code == 401 {
                forgetToken()
            }
            throw QQBotError.api(code: code, message: message, path: path)
        }
        return json
    }

    private func send(_ request: URLRequest, label: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QQBotError.unreachable("\(label)：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QQBotError.badResponse("\(label) 返回的不是 JSON："
                + String(decoding: data.prefix(160), as: UTF8.self))
        }
        guard (200..<300).contains(status) else {
            let message = (json["message"] as? String) ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw QQBotError.http(status: status, body: message, path: label)
        }
        return json
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let text = value as? String { return Double(text) }
        return nil
    }
}

enum QQBotError: LocalizedError {
    case notConfigured
    case unreachable(String)
    case http(status: Int, body: String, path: String)
    case api(code: Int, message: String, path: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填机器人的 AppID / AppSecret。去「我 → 设置 → QQ 机器人」填上。"
        case let .unreachable(reason):
            return "连不上 QQ 开放平台：\(reason)"
        case let .http(status, body, path):
            return "QQ 平台在 \(path) 返回 HTTP \(status)：\(body.prefix(140))"
        case let .api(code, message, path):
            var hint = ""
            switch code {
            case 11244, 11253:
                hint = "（token 失效了，重连一次）"
            case 304003, 304004:
                hint = "（主动消息没权限 —— 只能被动回复别人的消息）"
            case 22009:
                hint = "（回复窗口过了：同一条消息只能回 5 次、且要在几分钟内）"
            case 304023:
                hint = "（消息被平台风控拦了，换个说法再试）"
            default:
                hint = ""
            }
            return "QQ 平台拒绝了 \(path)：\(code) \(message)\(hint)"
        case let .badResponse(text):
            return "QQ 平台返回的内容看不懂：\(text.prefix(140))"
        }
    }
}
