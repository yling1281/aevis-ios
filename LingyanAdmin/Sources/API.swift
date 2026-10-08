import Foundation

/// 接口层错误。`status < 0` 表示**根本没连上**（网络问题），
/// `401` 表示**登录已过期**，`403` 表示**权限不够** —— 这三种要分开告诉用户，
/// 不然用户会一直去检查网络。
struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// 后台接口客户端（对应服务端 app_server 那一套 /api/* 管理端点）。
///
/// 鉴权：登录拿 JWT → 之后每个请求带 `Authorization: Bearer <token>`。
/// 令牌一旦被服务器判成无效（账号删了 / 权限撤了 / 过期），这里会**自动退出登录**，
/// 界面自己回到登录页 —— 免得用户对着一个永远 401 的界面反复点重试。
final class API {
    static let shared = API()

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
        let b = base ?? AppConfig.shared.baseURL
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

    /// 账号密码登录。还没令牌，所以这一步不能带 Authorization。
    func login(server: String, username: String, password: String) async throws -> [String: Any] {
        let base = AppConfig.normalize(server)
        guard let u = makeURL("/api/auth/login", base: base) else {
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
            throw APIError(status: 0, message: "服务器地址不合法：\(AppConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        return try await send(req)
    }

    func post(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        try await sendBody(path, method: "POST", body: body)
    }

    func put(_ path: String, body: [String: Any] = [:]) async throws -> [String: Any] {
        try await sendBody(path, method: "PUT", body: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = makeURL(path, query: query) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(AppConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "DELETE"
        return try await send(req)
    }

    /// ⚠️ 这个方法**不能**叫 `body` —— 上面 post/put 的形参也叫 `body`，
    ///    同名会把方法遮住，编译报「cannot call value of non-function type '[String : Any]'」。
    ///    （2026-10-08 run #5 就是这么挂的，`_ios/check_swift.py` 现在会查这类同名遮蔽。）
    private func sendBody(_ path: String, method: String, body: [String: Any]) async throws -> [String: Any] {
        guard let u = makeURL(path) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(AppConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try await send(req)
    }

    private func send(_ req: URLRequest, base: String? = nil, auth: Bool = true) async throws -> [String: Any] {
        var r = req
        if auth {
            let t = AppConfig.shared.token
            if !t.isEmpty { r.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        }
        r.setValue("LingyanAdmin-iOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: r)
        } catch {
            let b = base ?? AppConfig.shared.baseURL
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
            // 令牌废了：立刻清掉，界面自己回登录页（别再让用户对着 401 点重试）
            if auth {
                DispatchQueue.main.async { AppConfig.shared.signOut() }
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

// MARK: - 手写 JSON 取值（服务端字段多、又都是可选的，用 Codable 反而更脆）

extension Dictionary where Key == String, Value == Any {
    func s(_ k: String) -> String {
        if let v = self[k] as? String { return v }
        if let v = self[k] as? NSNumber { return v.stringValue }
        return ""
    }

    func i(_ k: String) -> Int {
        if let v = self[k] as? Int { return v }
        if let v = self[k] as? NSNumber { return v.intValue }
        if let v = self[k] as? String, let n = Int(v) { return n }
        return 0
    }

    func d(_ k: String) -> Double {
        if let v = self[k] as? Double { return v }
        if let v = self[k] as? NSNumber { return v.doubleValue }
        if let v = self[k] as? String, let n = Double(v) { return n }
        return 0
    }

    func b(_ k: String) -> Bool {
        if let v = self[k] as? Bool { return v }
        if let v = self[k] as? NSNumber { return v.intValue != 0 }
        if let v = self[k] as? String { return v == "1" || v.lowercased() == "true" }
        return false
    }

    func dict(_ k: String) -> [String: Any] { (self[k] as? [String: Any]) ?? [:] }
    func list(_ k: String) -> [[String: Any]] { (self[k] as? [[String: Any]]) ?? [] }

    func strings(_ k: String) -> [String] {
        if let v = self[k] as? [String] { return v }
        if let v = self[k] as? [Any] { return v.map { "\($0)" } }
        return []
    }

    /// 有些字段服务端会给 null，这里统一成 ""
    func nz(_ k: String) -> String {
        if self[k] == nil || self[k] is NSNull { return "" }
        return s(k)
    }
}
