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
        // 2026-11-22 实测：香港这条所有 /v1/* 都 404（nginx 没挂 API）、
        // 直连是自签证书（iOS 报 SSL 错误）。两条都必须置空 = 不可用，
        // 否则用户点选后微信/QQ/登录全挂（老板实测「直连点不动、微信 SSL 错误」）。
        // 地址留在此处备注，待服务端 vhost/证书修好再放开。
        Line(id: "hk",   name: "香港", base: "", pinning: false, note: "暂不可用（接口未挂载）"),
        Line(id: "direct", name: "直连", base: "", pinning: true,  note: "暂不可用（自签证书）"),
        Line(id: "spare", name: "备用", base: "", pinning: false, note: "暂不可用")
    ]

    private static let activeKey = "apiLineId"

    /// 当前生效线路（重启沿用）。若持久化的是已失效线路，自动回落到默认，
    /// 避免「上次选了直连→这次启动就 SSL 错误」。
    static var activeLine: Line {
        let id = UserDefaults.standard.string(forKey: activeKey) ?? "bj"
        let picked = lines.first { $0.id == id } ?? lines[0]
        return picked.base.isEmpty ? lines[0] : picked
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
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else {
            let msg = (raw["msg"] as? String) ?? ""
            throw APIError.http(code, msg)
        }

        // 业务信封（2026-11-22 修）：服务端 ok()={code:200,data:{...},msg}、
        // err()={code:4111,data:null,msg}，且 **HTTP 恒 200**。以前只看 HTTP 状态、
        // 又从顶层读 json["token"]（实际在 data 里）→ 所有账号操作都报「数据解析失败」。
        // 这里统一：① 业务 code 非 200/0 就按 msg 抛；② 把 data 的键补到顶层（不覆盖），
        // 于是 json["token"] 和 json["data"]["token"] 两种写法都能取到，全线兼容。
        var json = raw
        if let biz = (raw["code"] as? NSNumber)?.intValue {
            if biz != 200 && biz != 0 {
                let msg = (raw["msg"] as? String) ?? "请求失败（\(biz)）"
                throw APIError.http(biz, msg)
            }
        }
        if let envelope = raw["data"] as? [String: Any] {
            for (k, v) in envelope where json[k] == nil { json[k] = v }
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

    /// 流式发一轮对话（SSE）：逐段把增量文本回调给 `onDelta`，返回拼好的完整文本。
    ///
    /// SSE 格式容错点（服务端实现不统一，逐个兜）：
    /// - 只认 `data:` 开头的行，`event:` / `:` 注释 / 空行等非 data 行一律忽略；
    /// - `data: [DONE]` 视为结束；
    /// - 每段 JSON 先剥一层信封 `data`，再按优先级找
    ///   `choices[0].delta.content` / `choices[0].message.content` / 顶层 `content`（另兼容 `text`）；
    /// - 最后一帧 `choices: []` 只带 usage、没有 content，必须跳过，不当成回复正文；
    /// - 某段解析失败（非 JSON、字段缺失）只 `continue`，不让整轮对话挂掉；
    /// - **兜底**：整条流没吐出任何增量（服务端忽略 `stream:true` 或只回非 SSE）时，
    ///   回退到非流式 `sendChat` 拿整段并补一次 `onDelta`，保证界面不会空白卡死。
    static func sendChatStream(
        token: String,
        model: String,
        messages: [[String: String]],
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let host = activeLine.base
        guard !host.isEmpty else { throw APIError.http(0, "线路暂不可用") }
        guard let url = URL(string: host + "/v1/llm/chat") else {
            throw APIError.decode("bad url: /v1/llm/chat")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 首字节可能较慢，给足超时；只要持续有数据就不会触发
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages, "stream": true
        ])

        // 用当前线路的 session（直连走自签证书 pinning），与底层 request 保持一致
        let (bytes, resp) = try await session.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw APIError.http(code, "") }

        var full = ""
        var gotAny = false
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty,
                  let raw = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let delta = Self.streamDelta(from: obj),
                  !delta.isEmpty else { continue }
            gotAny = true
            full += delta
            onDelta(delta)
        }

        // 一个增量都没有：服务端多半没做流式，回退非流式补上，避免空白卡死
        if !gotAny {
            let whole = try await sendChat(token: token, model: model, messages: messages)
            if !whole.isEmpty { onDelta(whole) }
            return whole
        }
        return full
    }

    /// 从一段 SSE JSON 里挖出文本增量；挖不到返回 nil（调用方 `continue`）。
    /// 优先级对齐生产契约（aevis_llm.py:2573-2637）：先 `choices[0].delta.content`，
    /// 兼容 `choices[0].message.content` 与顶层 `content`；`choices: []` 的 usage 帧会落到最后返回 nil。
    private static func streamDelta(from obj: [String: Any]) -> String? {
        let d = (obj["data"] as? [String: Any]) ?? obj
        let choices = (d["choices"] as? [[String: Any]]) ?? (obj["choices"] as? [[String: Any]])
        if let first = choices?.first {
            if let delta = first["delta"] as? [String: Any],
               let s = delta["content"] as? String, !s.isEmpty { return s }
            if let msg = first["message"] as? [String: Any],
               let s = msg["content"] as? String, !s.isEmpty { return s }
            if let s = first["text"] as? String, !s.isEmpty { return s }
        }
        // 兼容非标准实现：顶层 content/text。usage 帧（choices 为空）走到这里也取不到，返回 nil。
        for key in ["content", "text"] {
            if let s = d[key] as? String, !s.isEmpty { return s }
            if let s = obj[key] as? String, !s.isEmpty { return s }
        }
        return nil
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
                // 只认 2xx/3xx；404（香港那种"nginx 在但没挂 API"）以前被算成可用，
                // 导致坏线路进了自动切换候选，必须排除。
                if (200..<400).contains(code) {
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
