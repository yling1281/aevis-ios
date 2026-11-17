import Foundation

/// 所有网络请求（2026-11-17，134 骨架）。
///
/// BASE 用北京隧道 `https://q7m3ax.lingyan.cyou` —— 直连 54319 是自签证书，iOS 不认（安卓靠
/// `network_security_config` 内置信任，iOS 要描述文件/ATS 例外，骨架阶段不做）。
///
/// 契约与安卓完全一致；错误一律抛 `APIError`，由 View 决定怎么显示。
enum APIError: LocalizedError {
    case http(Int, String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, msg): return msg.isEmpty ? "网络异常（HTTP \(code)）" : msg
        case let .decode(m): return "数据解析失败：\(m)"
        }
    }
}

struct APIClient {
    static let base = "https://q7m3ax.lingyan.cyou"

    // MARK: - 底层

    static func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil,
        account: String? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else {
            throw APIError.decode("bad url: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let account { req.setValue(account, forHTTPHeaderField: "X-Account") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = (json["msg"] as? String) ?? ""
            throw APIError.http(code, msg)
        }
        return json
    }

    // MARK: - 账号

    struct LoginResult { let token: String; let uid: String }

    static func login(email: String, password: String) async throws -> LoginResult {
        let json = try await request(
            "/v1/auth/login/email", method: "POST",
            body: ["email": email, "password": password]
        )
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw APIError.decode("没有 token")
        }
        return LoginResult(token: token, uid: json["uid"] as? String ?? "")
    }

    static func me(token: String) async throws -> [String: Any] {
        try await request("/v1/me", token: token)
    }

    // MARK: - 角色

    static func myPersonas(token: String, email: String) async throws -> [Persona] {
        let json = try await request("/v1/psquare/mine", token: token, account: email)
        let data = (json["data"] as? [String: Any]) ?? json
        let rows = (data["rows"] as? [[String: Any]]) ?? (data["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { Persona(json: $0) }
    }

    // MARK: - 聊天

    static func backupMeta(token: String) async throws -> (count: Int, bytes: Int, at: String) {
        let json = try await request("/v1/chat/backup", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["count"] as? Int ?? 0, d["bytes"] as? Int ?? 0, d["at"] as? String ?? "")
    }

    /// 恢复码 → 备份 JSON 原文（结构是 `{convs:{pid:[msg]}}` 或扁平 map，两种都要认）。
    static func recover(code: String) async throws -> String {
        let json = try await request(
            "/v1/chat/recover", method: "POST", body: ["code": code]
        )
        let d = (json["data"] as? [String: Any]) ?? json
        guard let backup = d["backup"] as? String, !backup.isEmpty else {
            throw APIError.decode((json["msg"] as? String) ?? "这个恢复码还没有备份")
        }
        return backup
    }

    static func recoverCode(token: String) async throws -> String {
        let json = try await request("/v1/chat/recover/code", method: "POST", body: [:], token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["code"] as? String) ?? (json["code"] as? String) ?? ""
    }

    /// 发一轮对话（骨架阶段用非流式；流式留给下一版接 SSE）。
    static func sendChat(
        token: String,
        model: String,
        messages: [[String: String]]
    ) async throws -> String {
        let json = try await request(
            "/v1/llm/chat", method: "POST",
            body: ["model": model, "messages": messages, "stream": false],
            token: token
        )
        let d = (json["data"] as? [String: Any]) ?? json
        if let text = d["content"] as? String { return text }
        if let choices = d["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let text = msg["content"] as? String { return text }
        throw APIError.decode("没有回复正文")
    }

    // MARK: - P0 其余（139 E-1）
    //
    // 只补第一版真正会用到的：配置 / 更新日志 / 邮箱验证码登录 / 模型列表 / 余额 /
    // 表情列表 / 媒体上传 / 备份推送。P2（QQ、微信、支付、账号卡、会话管理、web auth）
    // **故意不实现** —— 界面上也不放入口，避免"点了没反应"。

    static func appConfig() async throws -> [String: Any] {
        try await request("/v1/app/config")
    }

    static func changelog() async throws -> [String: Any] {
        try await request("/v1/app/changelog")
    }

    /// 发邮箱验证码（登录用）。
    static func sendEmailCode(email: String) async throws {
        _ = try await request(
            "/v1/auth/email/code", method: "POST", body: ["email": email]
        )
    }

    /// 验证码登录。
    static func loginByCode(email: String, code: String) async throws -> LoginResult {
        let json = try await request(
            "/v1/auth/login/email-code", method: "POST",
            body: ["email": email, "code": code]
        )
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw APIError.decode((json["msg"] as? String) ?? "没有 token")
        }
        return LoginResult(token: token, uid: json["uid"] as? String ?? "")
    }

    /// 注册。
    static func register(email: String, password: String, code: String) async throws -> LoginResult {
        let json = try await request(
            "/v1/auth/register", method: "POST",
            body: ["email": email, "password": password, "code": code]
        )
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw APIError.decode((json["msg"] as? String) ?? "没有 token")
        }
        return LoginResult(token: token, uid: json["uid"] as? String ?? "")
    }

    struct ModelInfo { let id: String; let name: String }

    static func models(token: String) async throws -> [ModelInfo] {
        let json = try await request("/v1/llm/models", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        let arr = (d["models"] as? [[String: Any]]) ?? (d["rows"] as? [[String: Any]]) ?? []
        return arr.compactMap {
            guard let id = ($0["id"] as? String) ?? ($0["name"] as? String) else { return nil }
            return ModelInfo(id: id, name: ($0["name"] as? String) ?? id)
        }
    }

    static func balance(token: String) async throws -> Int {
        let json = try await request("/v1/llm/balance", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["balance"] as? Int) ?? (d["points"] as? Int) ?? 0
    }

    static func emojiList(token: String) async throws -> [[String: Any]] {
        let json = try await request("/v1/emoji/list", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["rows"] as? [[String: Any]]) ?? (d["items"] as? [[String: Any]]) ?? []
    }

    /// 上传图片，返回服务端相对路径（安卓同接口、同字段）。
    static func uploadImage(token: String, data: Data, filename: String) async throws -> String {
        guard let url = URL(string: base + "/v1/media") else { throw APIError.decode("bad url") }
        let boundary = "Boundary-" + UUID().uuidString
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=" + boundary,
                     forHTTPHeaderField: "Content-Type")

        let crlf = "\r\n"
        var body = Data()
        body.append(("--" + boundary + crlf).data(using: .utf8)!)
        body.append(("Content-Disposition: form-data; name=\"file\"; filename=\"" + filename + "\"" + crlf).data(using: .utf8)!)
        body.append(("Content-Type: image/jpeg" + crlf + crlf).data(using: .utf8)!)
        body.append(data)
        body.append((crlf + "--" + boundary + "--" + crlf).data(using: .utf8)!)
        req.httpBody = body

        let (respData, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            throw APIError.http(code, (json["msg"] as? String) ?? "")
        }
        let d = (json["data"] as? [String: Any]) ?? json
        let path = (d["url"] as? String) ?? (d["path"] as? String) ?? ""
        guard !path.isEmpty else { throw APIError.decode("上传没有返回路径") }
        return path
    }

    /// 把本地会话推上云端（备份）。结构照安卓：`{convs:{pid:[…]}}`。
    static func backupPush(token: String, convs: [String: [[String: String]]]) async throws {
        _ = try await request(
            "/v1/chat/backup", method: "POST", body: ["convs": convs], token: token
        )
    }

    // MARK: - 微信扫码登录（2026-11-17，146）

    struct QRInfo { let id: String; let content: String }

    /// `POST /v1/auth/wx/qr/create` → `{id, content}`（字段名两种都兼容）
    static func wxQRCreate() async throws -> QRInfo {
        let json = try await request("/v1/auth/wx/qr/create", method: "POST", body: [:])
        let d = (json["data"] as? [String: Any]) ?? json
        let id = (d["id"] as? String) ?? (d["qr_id"] as? String) ?? (d["ticket"] as? String) ?? ""
        let content = (d["content"] as? String) ?? (d["url"] as? String)
            ?? (d["qr_url"] as? String) ?? (d["qrcode"] as? String) ?? ""
        guard !content.isEmpty else {
            throw APIError.decode((json["msg"] as? String) ?? "二维码内容为空")
        }
        return QRInfo(id: id, content: content)
    }

    /// `POST /v1/auth/wx/qr/poll` → 有 token 返回 token，否则 nil（未扫/待确认）
    static func wxQRPoll(id: String) async throws -> String? {
        let json = try await request(
            "/v1/auth/wx/qr/poll", method: "POST", body: ["id": id]
        )
        let d = (json["data"] as? [String: Any]) ?? json
        if let t = d["token"] as? String, !t.isEmpty { return t }
        if let t = json["token"] as? String, !t.isEmpty { return t }
        return nil
    }
}
