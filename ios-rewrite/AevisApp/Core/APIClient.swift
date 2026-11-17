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
    /// 线路（2026-11-17，147/148）：UI 只显示名字，**地址一律不上屏**。
    struct Line: Identifiable, Equatable {
        let id: String        // 内部 key，也用作持久化
        let name: String      // 北京 / 香港 / 直连 / 备用
        let base: String      // 真实地址；留空 = 暂不可用
        let pinning: Bool     // 仅「直连」为 true（自签证书）
        var note: String = "" // 半窗里的短注（默认/备用/最快（自签证书））
    }

    static let lines: [Line] = [
        Line(id: "bj",   name: "北京", base: "https://q7m3ax.lingyan.cyou",     pinning: false, note: "默认（隧道）"),
        Line(id: "hk",   name: "香港", base: "https://lingyan.cyou",            pinning: false, note: "备用"),
        Line(id: "direct", name: "直连", base: "https://103.236.72.107:54319",  pinning: true,  note: "最快（自签证书）"),
        // 148：第 4 条先留空位（服务端 vhost 未修好），点了给「暂不可用」，不指向 404 地址
        Line(id: "spare", name: "备用", base: "",                               pinning: false, note: "暂不可用")
    ]

    private static let activeKey = "apiLineId"

    /// 当前生效线路（重启沿用）。
    static var activeLine: Line {
        let id = UserDefaults.standard.string(forKey: activeKey) ?? "bj"
        return lines.first { $0.id == id } ?? lines[0]
    }

    static func setActiveLine(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        Self.session = makeSession(for: activeLine)
    }

    /// 兼容旧代码（头像相对路径拼接等）：默认线路的地址。
    static var base: String { activeLine.base.isEmpty ? lines[0].base : activeLine.base }

    // MARK: - 自签证书 pinning（仅 host:port 一处）

    /// 只对「直连」这条的 host + 端口接受 server trust，其它一律系统默认校验。
    /// **不允许**从服务端下发开关；这里写死。
    final class PinDelegate: NSObject, URLSessionDelegate {
        static let host = "103.236.72.107"
        static let port = 54319

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.host == Self.host,
                  challenge.protectionSpace.port == Self.port,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static func makeSession(for line: Line) -> URLSession {
        if line.pinning {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            return URLSession(configuration: cfg, delegate: PinDelegate(), delegateQueue: nil)
        }
        return .shared
    }

    /// 当前线路用的 session（pin 只影响直连这一条）
    private(set) static var session: URLSession = makeSession(for: activeLine)

    /// 线路是否可用（地址为空 = 暂不可用）
    static var activeAvailable: Bool { !activeLine.base.isEmpty }

    // MARK: - 底层

    static func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil,
        account: String? = nil
    ) async throws -> [String: Any] {
        let host = activeLine.base
        guard !host.isEmpty else { throw APIError.http(0, "线路暂不可用") }
        guard let url = URL(string: host + path) else {
            throw APIError.decode("bad url: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let account { req.setValue(account, forHTTPHeaderField: "X-Account") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }

        let (data, resp) = try await session.data(for: req)
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

    struct WXQR {
        let ticket: String
        let jumpURL: String    // weixin://dl/business/… 直接唤起小程序
        let imageURL: String   // /v1/auth/wx/qr/image?t=… 兜底二维码
    }

    /// `POST /v1/auth/wx/qr/create` → jump_url / image_url / ticket（149 实测字段）
    static func wxQRCreate() async throws -> WXQR {
        let json = try await request("/v1/auth/wx/qr/create", method: "POST", body: [:])
        let d = (json["data"] as? [String: Any]) ?? json
        return WXQR(
            ticket: (d["ticket"] as? String) ?? "",
            jumpURL: (d["jump_url"] as? String) ?? "",
            imageURL: (d["image_url"] as? String) ?? ""
        )
    }

    /// `POST /v1/auth/wx/qr/poll`（带 ticket）→ 有 token 返回 token，未确认返回 nil
    static func wxQRPoll(ticket: String) async throws -> String? {
        let json = try await request(
            "/v1/auth/wx/qr/poll", method: "POST", body: ["ticket": ticket]
        )
        let d = (json["data"] as? [String: Any]) ?? json
        if let t = d["token"] as? String, !t.isEmpty { return t }
        if let t = json["token"] as? String, !t.isEmpty { return t }
        return nil
    }

    // MARK: - QQ 网页授权（149：服务端已配 client_id，不需要 AppID）

    struct QQAuth { let url: String; let state: String }

    static func qqAuthURL() async throws -> QQAuth {
        let json = try await request("/v1/auth/qq/url", method: "POST", body: [:])
        let d = (json["data"] as? [String: Any]) ?? json
        let url = (d["auth_url"] as? String) ?? (d["url"] as? String) ?? ""
        guard !url.isEmpty else { throw APIError.decode((json["msg"] as? String) ?? "授权地址为空") }
        return QQAuth(url: url, state: (d["state"] as? String) ?? "")
    }

    static func qqLogin(code: String, state: String) async throws -> String {
        let json = try await request(
            "/v1/auth/qqlogin", method: "POST", body: ["code": code, "state": state]
        )
        let d = (json["data"] as? [String: Any]) ?? json
        if let t = d["token"] as? String, !t.isEmpty { return t }
        if let t = json["token"] as? String, !t.isEmpty { return t }
        throw APIError.decode((json["msg"] as? String) ?? "QQ 登录失败")
    }

    /// 回调前缀（服务端 redirect_uri），WKWebView 拦到它就从 query 取 code
    static let qqCallbackPrefix = "https://aevis.cn/prod-api/aevis/v1/auth/qq/callback"

    // MARK: - 测速 / 自动切换（2026-11-17，147）

    enum LineState: Equatable {
        case probing
        case ok(Int)          // 毫秒（3 次中位数）
        case timeout
        case certFailed       // 仅直连：pin 没通过
        case unavailable      // 地址为空
    }

    /// 探一条线路：`GET {base}/v1/app/config`，2s 超时，3 次取中位数。
    static func probe(_ line: Line) async -> LineState {
        if line.base.isEmpty { return .unavailable }
        var samples: [Int] = []
        var certFail = false
        for _ in 0..<3 {
            var req = URLRequest(url: URL(string: line.base + "/v1/app/config")!)
            req.timeoutInterval = 2
            let sess = makeSession(for: line)
            let t0 = Date()
            do {
                let (_, resp) = try await sess.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if (200..<500).contains(code) {
                    samples.append(Int(Date().timeIntervalSince(t0) * 1000))
                }
            } catch {
                let ns = error as NSError
                // -1202/-1200 = 证书/信任问题，直连要单独报「证书失败」，别混成超时
                if line.pinning && (ns.code == -1202 || ns.code == -1200) { certFail = true }
            }
        }
        if certFail && samples.isEmpty { return .certFailed }
        guard !samples.isEmpty else { return .timeout }
        return .ok(samples.sorted()[samples.count / 2])
    }

    /// 带一次自动切换的请求：失败就换下一条可用线路重试一次，并记住。
    static func requestWithFailover(
        _ path: String, method: String = "GET",
        body: [String: Any]? = nil, token: String? = nil, account: String? = nil
    ) async throws -> [String: Any] {
        do {
            return try await request(path, method: method, body: body, token: token, account: account)
        } catch {
            let current = activeLine
            guard let next = lines.first(where: { $0.id != current.id && !$0.base.isEmpty }) else {
                throw error
            }
            setActiveLine(next.id)
            lastSwitchNote = "当前线路不可用，已切到 \(next.name)"
            return try await request(path, method: method, body: body, token: token, account: account)
        }
    }

    /// 最近一次自动切换提示（列表/登录页顶部条用；读过即清）。
    static var lastSwitchNote: String = ""
}
