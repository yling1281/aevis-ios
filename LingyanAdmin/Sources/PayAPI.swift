import Foundation

/// 码支付后台（payadmin）的接口客户端。
///
/// 鉴权走**请求头** —— `X-Pay-Token: <令牌>`（服务端 `current_user()` 两种都认，
/// 见 payadmin/app.py 里的 `_header_token`）。为什么不用 Cookie：
/// App 没有浏览器那种 Cookie 罐，URLSession 的 Cookie 存储跨重启、跨进程都不靠谱，
/// 而且真出问题时「到底带没带 Cookie」在手机上根本没法看。
///
/// 错误口径和 `API` 完全一致（复用同一个 `APIError`）：
/// `status < 0` = 根本没连上；`401` = 令牌废了（**自动退出登录**）；`403` = 权限不够。
final class PayAPI {
    static let shared = PayAPI()

    private let session: URLSession

    private init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    // MARK: - 拼地址

    func makeURL(_ path: String, query: [String: String] = [:], base: String? = nil) -> URL? {
        let b = base ?? PayConfig.shared.baseURL
        guard var comps = URLComponents(string: b + path) else { return nil }
        if !query.isEmpty {
            var items: [URLQueryItem] = comps.queryItems ?? []
            for (k, v) in query where !v.isEmpty {
                items.append(URLQueryItem(name: k, value: v))
            }
            comps.queryItems = items
        }
        return comps.url
    }

    // MARK: - 登录

    /// 账号密码登录（和电脑上登 `/payadmin/` 是同一个账号）。还没令牌，这一步不带鉴权头。
    func login(server: String, username: String, password: String) async throws -> [String: Any] {
        let base = PayConfig.normalize(server)
        guard let u = makeURL("/api/login", base: base) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ]
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try await send(req, base: base, auth: false)
    }

    // MARK: - 通用请求

    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = makeURL(path, query: query) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(PayConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        return try await send(req)
    }

    func post(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        try await sendJSON(path, method: "POST", fields: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = makeURL(path, query: query) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(PayConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "DELETE"
        return try await send(req)
    }

    /// ⚠️ 形参**不能**叫 `body` 再套一个叫 `body` 的名字 —— 形参会把方法遮住
    ///    （素材后台那边 `API.swift` 就为这个挂过一轮，见那里的血泪注释）。
    private func sendJSON(_ path: String, method: String, fields: [String: Any]) async throws -> [String: Any] {
        guard let u = makeURL(path) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(PayConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        return try await send(req)
    }

    private func send(_ req: URLRequest, base: String? = nil, auth: Bool = true) async throws -> [String: Any] {
        var r = req
        if auth {
            let t = PayConfig.shared.token
            if !t.isEmpty { r.setValue(t, forHTTPHeaderField: "X-Pay-Token") }
        }
        r.setValue("LingyanAdmin-iOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: r)
        } catch {
            let b = base ?? PayConfig.shared.baseURL
            throw APIError(status: -1, message: "连不上服务器（\(b)）：\(error.localizedDescription)")
        }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var json: [String: Any] = [:]
        if let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any] {
            json = d
        }

        if code >= 200 && code < 300 { return json }

        var msg = (json["detail"] as? String) ?? ""
        if msg.isEmpty, json["detail"] != nil {
            msg = String(describing: json["detail"] ?? "")
        }
        if msg.isEmpty {
            msg = String(data: data.prefix(300), encoding: .utf8) ?? "HTTP \(code)"
        }

        if code == 401 {
            if auth {
                // 令牌废了：立刻清掉，这一侧自己回到登录页（别让用户对着 401 反复点重试）
                DispatchQueue.main.async { PayConfig.shared.signOut() }
                msg = msg.isEmpty ? "登录已过期，请重新登录" : msg
            } else {
                msg = msg.isEmpty ? "账号或密码不对" : msg
            }
        }
        if code == 403 { msg = "权限不够：\(msg)" }
        if code == 429 { msg = msg.isEmpty ? "尝试次数过多，请过一会儿再试" : msg }
        throw APIError(status: code, message: msg.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
