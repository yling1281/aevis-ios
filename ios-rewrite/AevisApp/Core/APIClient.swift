import Foundation
import UIKit

/// 所有网络请求。
///
/// 默认走北京隧道 `https://q7m3ax.lingyan.cyou`；四条线路（北京 / 香港 / 直连 / 备用）
/// 均已在 2026-11-23 生产实测可用。直连 `https://103.236.72.107:54319` 用自签证书，
/// 靠 `PinDelegate` 精确放行 host:port 的 serverTrust + Info.plist 的 ATS 例外双保险，
/// iOS 可正常使用（不再是"骨架阶段不做"）。线路地址一律不上屏，用户只见城市名。
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
        var note: String = "" // 半窗里的用户向短注（最快/默认/备用）
    }

    /// 线路顺序（2026-11-24 用户拍板）：「默认直连，实在不行切北京，还有备用，再是香港。」
    /// 数组顺序 = 回落顺序：直连 → 北京 → 备用 → 香港。UI 只显示名字，地址不上屏。
    ///
    /// 直连是自签证书（CN=103.236.72.107 / Aevis Direct CA，有效期至 2036），iOS 严格校验会
    /// 报 SSL 错误 → pinning=true 让 makeSession 挂 PinDelegate 放行该 host:port 的 serverTrust，
    /// Info.plist 的 NSExceptionDomains 也列了该 IP，双保险。443 不通，只走 54319。
    /// 真机大概率 SSL 失败 → 失败后按本数组顺序自动回落，并把失败线路记进 `failedLines`（降权），
    /// 下次启动直接跳过已知失败线路，不再每次先撞直连卡几秒。
    static let lines: [Line] = [
        // name 用服务器 IP 的**所在地**（2026-11-24 用户拍板，纯地名，不带任何 IP/后缀）：
        //   陕西 103.236.72.107（电信陕西云基地；.110 是同机另一入口，不单独成条）
        //   北京 123.57.33.160（阿里云）
        //   香港 38.76.168.61（aevis.cn 也解析到它，已合并成一条，避免出现两条「香港」）
        // 不出现任何 IP 字符串、日期、「自签证书/隧道」等工程词。
        // ⚠️ 数组顺序 = 回落顺序：陕西(直连) → 北京 → 香港，不要打乱。
        Line(id: "direct", name: "陕西", base: "https://103.236.72.107:54319",     pinning: true,  note: "最快"),
        Line(id: "bj",     name: "北京", base: "https://q7m3ax.lingyan.cyou",        pinning: false, note: "默认"),
        Line(id: "hk",     name: "香港", base: "https://lingyan.cyou/prod-api/aevis", pinning: false, note: "备用"),
    ]

    private static let activeKey = "apiLineId"
    /// 已知失败线路的 id 集合（持久化）：失败后降权，下次启动不优先撞它。
    private static let failedKey = "apiFailedLines"

    /// 用户明确选择的线路（不经失败降权）。默认 `direct`（用户拍板）。
    static var preferredLineID: String {
        UserDefaults.standard.string(forKey: activeKey) ?? "direct"
    }

    /// 已知失败的线路 id（逗号分隔持久化）。用于降权排序，不永久删除。
    static var failedLineIDs: Set<String> {
        let raw = UserDefaults.standard.string(forKey: failedKey) ?? ""
        return Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    /// 标记某线路失败（降权）。下次 `activeLine` 会跳过它（除非全失败）。
    static func markLineFailed(_ id: String) {
        var s = failedLineIDs
        s.insert(id)
        UserDefaults.standard.set(s.joined(separator: ","), forKey: failedKey)
    }

    /// 清除某线路的失败标记（探测成功 / 用户手动切换时调用）。
    static func clearLineFailed(_ id: String) {
        var s = failedLineIDs
        if s.contains(id) {
            s.remove(id)
            UserDefaults.standard.set(s.joined(separator: ","), forKey: failedKey)
        }
    }

    /// 有效回落顺序：首选（用户选择）优先，其次按 `lines` 数组顺序，跳过已知失败线路；
    /// 若所有线路都失败过，则回退到完整数组顺序（不能没有线路）。
    static var orderedLines: [Line] {
        let preferred = preferredLineID
        let failed = failedLineIDs
        var ordered: [Line] = []
        if let first = lines.first(where: { $0.id == preferred }) { ordered.append(first) }
        for l in lines where l.id != preferred { ordered.append(l) }
        let healthy = ordered.filter { !failed.contains($0.id) && !$0.base.isEmpty }
        return healthy.isEmpty ? ordered.filter { !$0.base.isEmpty } : healthy
    }

    /// 当前生效线路（重启沿用）。按回落顺序取第一条「地址非空且未标记失败」的线路。
    /// 若持久化的是真正失效线路（base 空），自动回到顺序第一条。
    static var activeLine: Line {
        // orderedLines 已把首选排到第一、过滤掉空地址与已知失败线（全失败时回退完整非空列表）
        orderedLines.first ?? lines[0]
    }

    static func setActiveLine(_ id: String) {
        UserDefaults.standard.set(id, forKey: activeKey)
        // 用户主动选择 = 信任它，清掉失败标记
        clearLineFailed(id)
        trialLineID = nil            // 真实切换，取消回落试用态
        Self.session = makeSession(for: activeLine)
    }

    /// 请求真正使用的线路：回落试用中（trialLineID）优先，否则用 activeLine。
    /// `request`/`sendChatStream`/`base` 都必须用它，保证 host 与 session 对应同一条线路。
    static var currentLine: Line {
        if let tid = trialLineID, let t = lines.first(where: { $0.id == tid }) {
            return t
        }
        return activeLine
    }

    /// 兼容旧代码（头像相对路径拼接等）：默认线路的地址。
    static var base: String { currentLine.base.isEmpty ? lines[0].base : currentLine.base }

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
        // 默认走「自动回落」：按 orderedLines（直连→北京→备用→香港）逐条试，
        // 只有线路级错误（SSL/连不上/超时/5xx）才换线；业务错误（401/402/4xx）立即抛。
        // 成功后确立该线路为首选并持久化 —— 真机直连 SSL 失败一次后，下次启动直接走北京，
        // 不再每次先撞直连卡几秒。所有调用方无需改动即获得回落能力。
        let ordered = orderedLines
        guard !ordered.isEmpty else { throw APIError.http(0, "线路暂不可用") }
        var lastError: Error?
        for (idx, line) in ordered.enumerated() {
            do {
                let json = try await attemptRequest(
                    path, method: method, body: body, token: token, account: account, line: line)
                clearLineFailed(line.id)
                if preferredLineID != line.id {
                    // 记住更优线路（例如直连失败后落到北京），下次启动直接用
                    UserDefaults.standard.set(line.id, forKey: activeKey)
                }
                if trialLineID != nil { trialLineID = nil }
                Self.session = makeSession(for: line)
                if idx > 0 { lastSwitchNote = "已切换到 \(line.name)" }
                return json
            } catch {
                lastError = error
                if Self.isLineError(error) {
                    markLineFailed(line.id)     // 降权，下次不再优先撞
                    continue
                }
                throw error                     // 业务错误不换线
            }
        }
        trialLineID = nil
        throw lastError ?? APIError.http(0, "所有线路不可用")
    }

    /// 单次请求（指定线路，不改全局状态）。`request` 的回落循环用它。
    private static func attemptRequest(
        _ path: String,
        method: String,
        body: [String: Any]?,
        token: String?,
        account: String?,
        line: Line
    ) async throws -> [String: Any] {
        let host = line.base
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

        let sess = makeSession(for: line)       // 直连带 PinDelegate，其它用 shared
        let (data, resp) = try await sess.data(for: req)
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
        messages: [[String: String]],
        temperature: Double? = nil
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if let temperature { body["temperature"] = temperature }
        let json = try await request(
            "/v1/llm/chat", method: "POST",
            body: body,
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
        temperature: Double? = nil,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        // 线路回落：按 orderedLines（直连→北京→备用→香港）逐条试，线路级错误才换线。
        // 注意流式一旦开始吐字就不能中途换线，否则会出现半截回复 —— 故回落只在
        // 「连接阶段失败（一个增量都没出）」时进行；已出字后失败由上层原地提示重发。
        let ordered = orderedLines
        guard !ordered.isEmpty else { throw APIError.http(0, "线路暂不可用") }
        var lastError: Error?
        for (idx, line) in ordered.enumerated() {
            // emitted 记录本条线路是否已经吐过字 —— 已出字后绝不换线重来（会重复内容）
            var emitted = false
            do {
                let (full, gotAny) = try await attemptChatStream(
                    line: line, token: token, model: model, messages: messages,
                    temperature: temperature,
                    onDelta: { d in emitted = true; onDelta(d) })
                clearLineFailed(line.id)
                if preferredLineID != line.id {
                    UserDefaults.standard.set(line.id, forKey: activeKey)
                }
                trialLineID = nil
                Self.session = makeSession(for: line)
                if idx > 0 { lastSwitchNote = "已切换到 \(line.name)" }
                // 没吐出任何增量（服务端没流式）：回退非流式补一次，避免空白
                if !gotAny {
                    let whole = try await sendChat(token: token, model: model, messages: messages)
                    if !whole.isEmpty { onDelta(whole) }
                    return whole
                }
                return full
            } catch {
                lastError = error
                // 已经吐过字：不换线（否则新线路的内容会重复拼到同一气泡），直接抛给上层
                if emitted { throw error }
                if Self.isLineError(error) {
                    markLineFailed(line.id)
                    continue
                }
                throw error
            }
        }
        trialLineID = nil
        throw lastError ?? APIError.http(0, "所有线路不可用")
    }

    /// 单次 SSE 流式请求（指定线路）。返回 (完整文本, 是否收到过增量)。
    private static func attemptChatStream(
        line: Line, token: String, model: String,
        messages: [[String: String]], temperature: Double?,
        onDelta: @escaping (String) -> Void
    ) async throws -> (String, Bool) {
        let host = line.base
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
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if let temperature { body["temperature"] = temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 该线路独立 session（直连走自签 pinning）
        let sess = makeSession(for: line)
        let (bytes, resp) = try await sess.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw APIError.http(code, "") }

        var full = ""
        var gotAny = false
        for try await raw in bytes.lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let delta = Self.streamDelta(from: obj),
                  !delta.isEmpty else { continue }
            gotAny = true
            full += delta
            onDelta(delta)
        }
        return (full, gotAny)
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

    // MARK: - 商城（墨点 / 会员套餐）
    //
    // 字段严格对齐服务端源码：
    //   aevis_points_shop.py:494 packages() → code/name/amountCents/amountYuan/points/pointsText
    //   aevis_points_shop.py:769 points_home() → points/yuan/rate/items
    //   aevis_shop.py:646 shop_products() → id/title/days/price_cents

    /// 墨点充值档位。字段对齐 /v1/points/recharge/packages 的 items[]。
    struct PointPackage: Identifiable {
        let code: String
        let name: String
        let amountCents: Int
        let amountYuan: String
        let points: Int
        let pointsText: String
        var id: String { code }
    }

    /// 充值档位列表（公开接口，不需登录即可展示价格）。顶层 `items`。
    static func pointPackages() async throws -> [PointPackage] {
        let json = try await request("/v1/points/recharge/packages")
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["items"] as? [[String: Any]]) ?? (json["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let code = r["code"] as? String else { return nil }
            let cents = (r["amountCents"] as? NSNumber)?.intValue ?? 0
            return PointPackage(
                code: code,
                name: (r["name"] as? String) ?? "",
                amountCents: cents,
                amountYuan: (r["amountYuan"] as? String) ?? String(format: "%.2f", Double(cents) / 100),
                points: (r["points"] as? NSNumber)?.intValue ?? 0,
                pointsText: (r["pointsText"] as? String) ?? ""
            )
        }
    }

    /// 墨点余额（需登录）。取不到时调用方显示「—」，不要显示 0。
    static func pointsBalance(token: String?) async throws -> Int {
        let json = try await request("/v1/points", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["points"] as? NSNumber)?.intValue ?? (json["points"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - 主页用量（真实数据，2026-11-24）

    /// 本周额度状态。服务端 `GET /v1/quota/state`（Bearer）：
    /// `data = { ok, quota: { active, percent, left_pct, has_quota } }`。
    /// 产品要求**只展示百分比、不给具体点数**，所以这里也只有百分比。
    /// 拉取失败 / 未登录时调用方显示「—」，绝不回落到任何写死的数字。
    struct QuotaState {
        let active: Bool        // 是否会员（免费用户也有周额度，口径一致）
        let percent: Int        // 本周已用百分比 0–100
        let leftPct: Int        // 本周剩余百分比 0–100
        let hasQuota: Bool      // 还有没有可用额度
    }

    static func quotaState(token: String?) async throws -> QuotaState {
        let json = try await request("/v1/quota/state", token: token)
        // 外层信封 {"code":200,"data":{...}} 已被 request 摊平到顶层，两种结构都兜一下
        let d = (json["data"] as? [String: Any]) ?? json
        let q = (d["quota"] as? [String: Any]) ?? (json["quota"] as? [String: Any]) ?? d
        return QuotaState(
            active: (q["active"] as? Bool) ?? false,
            percent: (q["percent"] as? NSNumber)?.intValue ?? 0,
            leftPct: (q["left_pct"] as? NSNumber)?.intValue ?? 0,
            hasQuota: (q["has_quota"] as? Bool) ?? false
        )
    }

    /// 主页墨点余额 + 「还能聊多少条」。服务端 `GET /v1/points`（Bearer）：
    /// `data = { points, yuan, rate, items }`，后端正在追加
    /// `avg_msg_cost`（每条消息平均消耗墨点）与 `est_messages`（预计还能聊多少条）。
    /// 新字段没上线时按产品口径用 `points / 100` 兜底（**不是旧版的 /35**）。
    struct PointsHome {
        let points: Int
        let estMessages: Int
        let avgMsgCost: Double  // 0 = 服务端还没给这个字段
    }

    static func pointsHome(token: String?) async throws -> PointsHome {
        let json = try await request("/v1/points", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        let pts = (d["points"] as? NSNumber)?.intValue
            ?? (json["points"] as? NSNumber)?.intValue ?? 0
        let avg = (d["avg_msg_cost"] as? NSNumber)?.doubleValue ?? 0

        // 优先用服务端算好的 est_messages；没有就 points/avg；再没有就 points/100 兜底
        let est: Int
        if let e = (d["est_messages"] as? NSNumber)?.intValue, e > 0 {
            est = e
        } else if avg > 0 {
            est = Int(Double(pts) / avg)
        } else {
            est = pts / 100
        }
        return PointsHome(points: pts, estMessages: max(0, est), avgMsgCost: avg)
    }

    // MARK: - 天气（主页问候用，南昌）

    struct WeatherNow {
        let tempC: Int
        let descCN: String   // 中文描述；映射不到就保留英文原文
    }

    private static let weatherCacheKey = "aevis.weather.nanchang.v1"
    private static let weatherCacheAtKey = "aevis.weather.nanchang.v1.at"
    /// 缓存有效期 10 分钟
    private static let weatherTTL: TimeInterval = 600

    /// 南昌实时天气：直连 `https://wttr.in/Nanchang?format=j1`（HTTPS、免 key、免登录）。
    /// - 10 分钟内直接用 UserDefaults 缓存，避免每次进主页都打一次外网；
    /// - `force: true` 用于下拉刷新；
    /// - 3 秒超时，失败直接抛错，由调用方决定「不显示」——**绝不返回假数据**。
    /// ATS：wttr.in 是标准 HTTPS 证书，不需要动 Info.plist；不走 APIClient 的线路回落。
    static func weatherNanchang(force: Bool = false) async throws -> WeatherNow {
        let d = UserDefaults.standard
        if !force {
            let at = d.double(forKey: weatherCacheAtKey)
            if at > 0, Date().timeIntervalSince1970 - at < weatherTTL,
               let cached = d.dictionary(forKey: weatherCacheKey),
               let t = cached["temp"] as? Int,
               let desc = cached["desc"] as? String, !desc.isEmpty {
                return WeatherNow(tempC: t, descCN: desc)
            }
        }

        guard let url = URL(string: "https://wttr.in/Nanchang?format=j1") else {
            throw APIError.decode("bad weather url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        // wttr.in 对没有 UA 的请求偶尔会 400，给一个明确的 UA
        req.setValue("AevisApp/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, "天气服务不可用")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let cur = (json["current_condition"] as? [[String: Any]])?.first else {
            throw APIError.decode("天气数据解析失败")
        }
        // wttr.in 的 temp_C 是字符串 "18"；兼容个别情况下给数字
        var temp: Int? = (cur["temp_C"] as? NSNumber)?.intValue
        if temp == nil, let s = cur["temp_C"] as? String { temp = Int(s) }
        guard let temp else { throw APIError.decode("天气温度缺失") }
        let en = ((cur["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        let w = WeatherNow(tempC: temp, descCN: cnWeather(en))

        d.set(["temp": w.tempC, "desc": w.descCN], forKey: weatherCacheKey)
        d.set(Date().timeIntervalSince1970, forKey: weatherCacheAtKey)
        return w
    }

    /// wttr.in 只给英文天气描述，这里做一层轻量中文映射（映射不到就保留英文，不猜）。
    private static func cnWeather(_ en: String) -> String {
        let s = en.lowercased()
        if s.isEmpty { return "" }
        if s.contains("thunder") { return "雷阵雨" }
        if s.contains("snow") || s.contains("sleet") || s.contains("blizzard") { return "雪" }
        if s.contains("rain") || s.contains("drizzle") || s.contains("shower") { return "雨" }
        if s.contains("fog") || s.contains("mist") { return "雾" }
        if s.contains("overcast") { return "阴" }
        if s.contains("cloud") { return "多云" }
        if s.contains("sunny") || s.contains("clear") { return "晴" }
        return en
    }

    /// 会员套餐。字段对齐 /v1/shop/products 的 items[]（注意 price_cents 带下划线）。
    /// id 是字符串主键（aevis_shop.py：p_x / p_xl / p_xxl / p_xllll），**不是数字** ——
    /// 旧版声明成 Int 会让 `as? NSNumber` 全部解析失败、会员列表恒空、下单 product_id 传错。
    /// 2026-11-24 会员改「固定 30 天 + 按量 4 档」，新增 week_total / percent / label。
    struct ShopProduct: Identifiable {
        let id: String
        let title: String
        let days: Int
        let priceCents: Int
        var weekTotal: Int = 0      // 每周额度（墨点）：300/450/1050/2250
        var percent: Int = 0        // 展示百分比：100/150/350/750
        var label: String = ""      // 档位短名：X / XL / XXL / XLLLL
    }

    /// 会员套餐列表（公开接口）。顶层 `items`。
    static func shopProducts() async throws -> [ShopProduct] {
        let json = try await request("/v1/shop/products")
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["items"] as? [[String: Any]]) ?? (json["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            // 服务端 id 为字符串；容错兜数字（个别老部署可能下发 NSNumber）
            let ident: String
            if let s = r["id"] as? String, !s.isEmpty { ident = s }
            else if let n = r["id"] as? NSNumber { ident = n.stringValue }
            else { return nil }
            return ShopProduct(
                id: ident,
                title: (r["title"] as? String) ?? "",
                days: (r["days"] as? NSNumber)?.intValue ?? 0,
                priceCents: (r["price_cents"] as? NSNumber)?.intValue ?? 0,
                // 新字段容错：老服务端缺这些键时给 0/空串，不让解析崩
                weekTotal: (r["week_total"] as? NSNumber)?.intValue ?? 0,
                percent: (r["percent"] as? NSNumber)?.intValue ?? 0,
                label: (r["label"] as? String) ?? ""
            )
        }
    }

    // MARK: - 支付下单 / 查单（第 3 轮）
    //
    // 两套商品走各自的服务端接口，pay_url 都是易支付收银台（submit.php?...），
    // platform=ios 时服务端把 return_url 设成 aevis://pay?order=<单号>，付完能回 App。
    // 确认到账以「查单」为准，不信任前端跳转/回调：
    //   墨点 POST /v1/points/recharge       → orderNo / payUrl
    //        GET  /v1/points/recharge/<no>  → state(pending|paid|refunded) / points
    //   会员 POST /v1/shop/order            → order_id / pay_url / channel
    //        GET  /v1/shop/orders/<oid>     → state(pending|paid) / days

    /// 下单结果（墨点 / 会员统一形态）。
    struct PayOrder: Identifiable {
        enum Kind: String { case points, member }
        let orderID: String      // 查单用：墨点=orderNo，会员=order_id
        let payURL: String       // 易支付收银台地址
        let kind: Kind
        var id: String { kind.rawValue + "-" + orderID }
    }

    /// 查单结果：paid 表示已到账；amount 是到账墨点数或天数；unit 是展示单位。
    struct PayVerifyResult {
        let paid: Bool
        let amount: Int
        let unit: String
    }

    /// 墨点充值下单。payType 只接受 alipay / wxpay（服务端其它值回落 wxpay）。
    static func pointsRecharge(package code: String, payType: String, token: String) async throws -> PayOrder {
        let json = try await request(
            "/v1/points/recharge", method: "POST",
            body: ["package": code, "payType": payType, "platform": "ios"],
            token: token
        )
        let d = (json["data"] as? [String: Any]) ?? json
        guard let no = d["orderNo"] as? String, !no.isEmpty else {
            throw APIError.decode("下单没有返回订单号")
        }
        return PayOrder(orderID: no, payURL: (d["payUrl"] as? String) ?? "", kind: .points)
    }

    /// 墨点查单：state == "paid" 即到账，points 为到账墨点数。
    static func pointsOrderStatus(orderNo: String, token: String) async throws -> (paid: Bool, points: Int) {
        let enc = orderNo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderNo
        let json = try await request("/v1/points/recharge/\(enc)", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return ((d["state"] as? String) == "paid",
                (d["points"] as? NSNumber)?.intValue ?? 0)
    }

    /// 会员下单。productID 为字符串主键（p30/p90/p365），pay_type 只接受 alipay / wxpay。
    static func memberOrder(productID: String, payType: String, token: String) async throws -> PayOrder {
        let json = try await request(
            "/v1/shop/order", method: "POST",
            body: ["product_id": productID, "pay_type": payType],
            token: token
        )
        let d = (json["data"] as? [String: Any]) ?? json
        guard let oid = d["order_id"] as? String, !oid.isEmpty else {
            throw APIError.decode("下单没有返回订单号")
        }
        return PayOrder(orderID: oid, payURL: (d["pay_url"] as? String) ?? "", kind: .member)
    }

    /// 会员查单：state == "paid" 即到账，days 为到账天数。
    static func memberOrderStatus(orderID: String, token: String) async throws -> (paid: Bool, days: Int) {
        let enc = orderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderID
        let json = try await request("/v1/shop/orders/\(enc)", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return ((d["state"] as? String) == "paid",
                (d["days"] as? NSNumber)?.intValue ?? 0)
    }

    /// 会员剩余天数（从 /v1/me 容错解析 membership.days_left；读不到返回 nil，界面显示占位）。
    static func membershipDays(token: String) async throws -> Int? {
        let json = try await request("/v1/me", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        guard let m = d["membership"] as? [String: Any] else { return nil }
        return (m["days_left"] as? NSNumber)?.intValue
    }

    // MARK: - 设备标识（验证码限流按「设备 + 邮箱」）

    /// 稳定的设备 ID：首次用 IDFV 生成后落 UserDefaults，之后每次都读同一个值。
    /// 同一台设备多次调用（含重启 App）返回同一个 id，服务端的 60 秒冷却/每日次数
    /// 才能按设备维度生效；卸载重装才会换（IDFV 本身的语义），可接受。
    static var deviceID: String {
        let key = "aevisDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let fresh = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// 发邮箱验证码（登录 / 找回共用）。带上 device_id 供服务端按设备+邮箱限流。
    static func sendEmailCode(email: String) async throws {
        _ = try await request(
            "/v1/auth/email/code", method: "POST",
            body: ["email": email, "device_id": deviceID]
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

    // MARK: - 模型列表（2026-11-24 每角色独立选模型）

    /// 一个可对话模型（字段对齐 `GET /v1/llm/models` 的 data.models[]）。
    /// 该接口是**公开**的（无需登录也能拿），所以 `llmModels()` 不传 token。
    struct LLMModel: Identifiable, Equatable {
        let id: String          // 模型 id（deepseek-flash 等），发送时用
        let label: String       // 展示名（DeepSeek V4.1 Flash）
        let note: String        // 说明（可为空）
        let billing: String     // per_token / per_call
        let isDefault: Bool     // 服务端默认模型

        /// 计费方式的中文短标（给选择列表用）。
        var billingText: String {
            switch billing {
            case "per_token": return "按 token"
            case "per_call":  return "按次"
            default:          return billing.isEmpty ? "" : billing
            }
        }

        /// 右上角按钮用的短名：label 取不到就退回 id。
        var shortLabel: String {
            // 尽量短：优先括号前的部分，仍过长就截断
            let base = label.isEmpty ? id : label
            return base.count > 12 ? String(base.prefix(12)) + "…" : base
        }
    }

    /// 模型列表 + 服务端默认模型 id。公开接口，失败抛 `APIError`。
    struct LLMModelList {
        let defaultID: String
        let models: [LLMModel]
    }

    /// GET /v1/llm/models —— 公开接口（无需登录）。返回默认 id + 模型数组。
    static func llmModels() async throws -> LLMModelList {
        // 走 request（已内置线路回落）；该接口公开，不传 token 也能拿
        let json = try await request("/v1/llm/models")
        let d = (json["data"] as? [String: Any]) ?? json
        let defaultID = (d["default"] as? String) ?? "deepseek-flash"
        let arr = (d["models"] as? [[String: Any]])
            ?? (d["rows"] as? [[String: Any]])
            ?? (json["models"] as? [[String: Any]])
            ?? []
        let models: [LLMModel] = arr.compactMap { r in
            guard let id = (r["id"] as? String) ?? (r["name"] as? String), !id.isEmpty else { return nil }
            return LLMModel(
                id: id,
                label: (r["label"] as? String) ?? (r["name"] as? String) ?? id,
                note: (r["note"] as? String) ?? "",
                billing: (r["billing"] as? String) ?? "",
                isDefault: (r["default"] as? Bool) ?? (id == defaultID)
            )
        }
        return LLMModelList(defaultID: defaultID, models: models)
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

    // MARK: - Web 扫码登录 / 支付（与网页版 unified_site/assets/qrlogin.js 同接口）

    /// 网页版扫码登录/支付的二维码信息。
    /// 字段对齐 qrlogin.js：qr_url 是相对路径（自带 query），mini_url 是小程序码，
    /// ticket 用于轮询，code 是可选设备验证码，deep_link 用于「用 App 打开」。
    struct WebQR {
        let qrURL: String
        let miniURL: String
        let ticket: String
        let code: String
        let deepLink: String
    }

    /// 创建带登录态的二维码。POST /v1/web/auth/qr，body { device_id, scene }。
    /// 传 token 走 Authorization: Bearer —— 二维码因此携带当前登录态（网页版靠 cookie，App 靠 token）。
    /// token 由调用方从 Session 读取后传入，避免 APIClient 依赖 Session 单例。
    static func webAuthQR(scene: String = "", token: String?) async throws -> WebQR {
        let json = try await request(
            "/v1/web/auth/qr", method: "POST",
            body: ["device_id": deviceID, "scene": scene],
            token: token
        )
        return WebQR(
            qrURL: (json["qr_url"] as? String) ?? (json["qrUrl"] as? String) ?? "",
            miniURL: (json["mini_url"] as? String) ?? (json["miniUrl"] as? String) ?? "",
            ticket: (json["ticket"] as? String) ?? "",
            code: (json["code"] as? String) ?? "",
            deepLink: (json["deep_link"] as? String) ?? ""
        )
    }

    /// 网页版扫码轮询结果。GET /v1/web/auth/poll?t=<ticket>。
    /// status: pending / scanned / cancelled / expired / ok；ok 时带 token/uid/account/nickname。
    static func webAuthPoll(ticket: String, token: String?) async throws -> [String: Any] {
        let t = ticket.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ticket
        return try await request("/v1/web/auth/poll?t=\(t)", token: token)
    }

    // MARK: - 测速 / 自动切换（2026-11-17，147）

    enum LineState: Equatable {
        case probing
        case ok(Int)          // 毫秒（3 次中位数）
        case timeout
        case certFailed       // 仅直连：pin 没通过
        case unavailable      // 地址为空
    }

    /// 单次轻量探测，返回毫秒延迟；失败/超时返回 nil。供登录页线路选择 UI 显示延迟。
    ///
    /// 走 `GET {base}/v1/app/config`，超时 **3 秒**；每条线路独立 session（直连带 pinning）。
    /// 用户要求的方法名/签名固定为 `lineLatency(_:) async -> Int?`，LoginView 只调用它。
    static func lineLatency(_ line: Line) async -> Int? {
        guard !line.base.isEmpty, let url = URL(string: line.base + "/v1/app/config") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let sess = makeSession(for: line)     // 直连这条带 PinDelegate
        let t0 = Date()
        do {
            let (_, resp) = try await sess.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<400).contains(code) else { return nil }
            return Int(Date().timeIntervalSince(t0) * 1000)
        } catch {
            return nil
        }
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

    /// 兼容旧调用名：`request` 本身已内置回落，这里直接转发。
    static func requestWithFailover(
        _ path: String, method: String = "GET",
        body: [String: Any]? = nil, token: String? = nil, account: String? = nil
    ) async throws -> [String: Any] {
        try await request(path, method: method, body: body, token: token, account: account)
    }

    /// 回落试用态：非 nil 时 `currentLine` 优先用它（`request` 回落循环里不直接依赖它，
    /// 保留给未来单次试探场景；`request` 走的是 attemptRequest(line:) 不会污染全局）。
    private static var trialLineID: String?

    /// 判断是否「线路级错误」（值得换线）：SSL / 连不上 / 超时 / 线路不可用 / 5xx。
    /// 业务错误（401/402/403/4xx）不换线，直接抛给上层处理。
    static func isLineError(_ error: Error) -> Bool {
        if let api = error as? APIError, case let .http(code, _) = api {
            return code == 0 || (500...599).contains(code)
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed:
            return true
        default:
            return false
        }
    }

    /// 最近一次自动切换提示（列表/登录页顶部条用；读过即清）。
    static var lastSwitchNote: String = ""
}
