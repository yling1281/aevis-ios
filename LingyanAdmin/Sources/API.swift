import Foundation

/// 接口层错误。`status < 0` 表示**根本没连上**（网络问题），
/// `401/403` 表示**服务器不认这个 Key**——这两种要分开告诉用户，
/// 不然用户会一直去检查网络。
struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// 只读接口客户端（对应服务端 app_server/routers/openapi.py 的 /api/v1/*）。
/// 所有请求都带 `X-API-Key` 头；服务端只认 sha256 摘要，明文只存在手机本地。
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

    func makeURL(_ path: String, query: [String: String] = [:]) -> URL? {
        let base = AppConfig.shared.baseURL
        guard var comps = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty {
            var items: [URLQueryItem] = comps.queryItems ?? []
            for (k, v) in query where !v.isEmpty {
                items.append(URLQueryItem(name: k, value: v))
            }
            comps.queryItems = items
        }
        return comps.url
    }

    /// 给别人复制用的完整链接（把 Key 拼在 ?k= 上，浏览器点开就能下）
    func shareURL(_ path: String) -> String {
        let base = AppConfig.shared.baseURL
        let key = AppConfig.shared.apiKey
        return base + path + "?k=" + key
    }

    // MARK: - 请求

    func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        guard let u = makeURL(path, query: query) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(AppConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        return try await send(req)
    }

    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let u = makeURL(path) else {
            throw APIError(status: 0, message: "服务器地址不合法：\(AppConfig.shared.server)")
        }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        var r = req
        r.setValue(AppConfig.shared.apiKey, forHTTPHeaderField: "X-API-Key")
        r.setValue("LingyanAdmin-iOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: r)
        } catch {
            throw APIError(status: -1, message: "连不上服务器：\(error.localizedDescription)")
        }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        var json: [String: Any] = [:]
        if let obj = try? JSONSerialization.jsonObject(with: data), let d = obj as? [String: Any] {
            json = d
        }

        if code >= 200 && code < 300 { return json }

        var msg = (json["detail"] as? String) ?? ""
        if json["detail"] != nil, msg.isEmpty {
            msg = String(describing: json["detail"] ?? "")
        }
        if msg.isEmpty {
            msg = String(data: data.prefix(300), encoding: .utf8) ?? "HTTP \(code)"
        }
        if code == 401 { msg = "API Key 无效：\(msg)" }
        if code == 403 { msg = "这个 Key 没有权限：\(msg)" }
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
        return false
    }

    func dict(_ k: String) -> [String: Any] { (self[k] as? [String: Any]) ?? [:] }
    func list(_ k: String) -> [[String: Any]] { (self[k] as? [[String: Any]]) ?? [] }

    func strings(_ k: String) -> [String] {
        if let v = self[k] as? [String] { return v }
        if let v = self[k] as? [Any] { return v.map { "\($0)" } }
        return []
    }
}
