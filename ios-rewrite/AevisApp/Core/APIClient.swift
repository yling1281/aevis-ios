import Foundation
import UIKit

/// 所有网络请求。
///
/// 默认走直连 `https://103.236.72.107:54319`（2026-11-24 用户拍板恢复）：NAT 端口映射，
/// 实测 ~0.13s，比北京隧道（~0.15s）快一个数量级。
/// 直连自签证书，靠 `PinDelegate` 放行该 host:port 的 serverTrust + Info.plist ATS 例外；
/// 万一某台设备证书就是过不了，`request` 会自动回落到北京（见下方 orderedLines），
/// 不会卡死。线路地址一律不上屏，用户只见城市名。
///
/// 2026-11 用户决定**关闭原来的第三条境外备用线路**（延迟 0.5~1.4s 且长期不稳），
/// 线路收敛为 直连 → 北京 两条。删掉 `lines` 里的对应条目即可：`orderedLines`、
/// 失败降权、自动选择全部按数组长度自适应，无需改动任何逻辑。
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
        let name: String      // 北京 / 直连（现存两条线路）
        let base: String      // 真实地址；留空 = 暂不可用
        let pinning: Bool     // 仅「直连」为 true（自签证书）
        var note: String = "" // 半窗里的用户向短注（最快/默认/备用）
    }

    /// 内置线路表（编进 App 的兜底，**永远存在**，云端全挂也还有它）。
    ///
    /// 2026-11-25：改名为 `builtInLines`，并新增计算属性 `lines` = 内置 ∪ 云端
    /// （`AevisHosts.allAccountLines`）。所有已有调用点读 `APIClient.lines` 的代码
    /// 自动就能看到云端下发的线路，不用改一行；`AevisHosts` 也拿这张内置表做
    /// 拉配置的起点（避免 `lines` → `allAccountLines` → 拉配置的环）。
    ///
    /// 顺序 = 回落顺序。2026-11-27 用户拍板三地分工：
    /// **独立 IP 的 4-4 是主服务器，北京是备用，香港只做加速（不进线路表）**。
    ///
    /// - 4-4（`103.236.72.107:54319`）：机房只映射了这一个 HTTPS 端口，自签证书靠
    ///   `PinDelegate` 放行。它是对海外可达的那台（新机海外连不上，已下线）。
    /// - 北京（`q7m3ax.lingyan.cyou`）：公网 CA，国内快，主线路连不上时自动回落。
    static let builtInLines: [Line] = [
        Line(id: "direct", name: "独立IP", base: "https://103.236.72.107:54319",
             pinning: true, note: "主线路"),
        Line(id: "bj", name: "北京", base: "https://q7m3ax.lingyan.cyou",
             pinning: false, note: "备用"),
    ]

    /// 生效中的线路表：内置 ∪ 云端下发（按 base 去重、内置优先、云端已按实测 RTT 排序）。
    ///
    /// 顺序语义不变：数组顺序 = 回落顺序，`orderedLines` 仍在其上做「首选 / 失败降权」。
    /// 云端的数组顺序**不参与**优先级 —— 见 `AevisHosts` 里的三条硬约束。
    static var lines: [Line] { AevisHosts.allAccountLines }

    private static let activeKey = "apiLineId"
    /// 已知失败线路的 id 集合（持久化）：失败后降权，下次启动不优先撞它。
    private static let failedKey = "apiFailedLines"

    // MARK: - 自动换线（2026-11-25 调度契约）
    //
    // 只在自动模式下生效；用户手动选线会把 apiAutoLine 置 false，这里**绝不**改那个键，
    // 否则会把用户的手动选择悄悄覆盖掉。用户点「自动选择」才会恢复。
    private static let slowThresholdMs = 3000
    private static let autoSwitchCooldown: TimeInterval = 60
    /// 候选 RTT 至少快 20% 才换（<= 当前 × 0.8），避免来回跳。
    private static let minRTTImprovement: Double = 0.8
    /// 连续慢请求计数；任何一次低于阈值的请求都清零。
    private static var slowStreak = 0
    private static var lastAutoSwitchAt: Date?
    /// 防止并发 preload 时多个请求同时判定换线。
    private static var autoSwitching = false

    /// 自动模式是否开启。键不存在 = 默认自动（与 ServerStatusView 的 @AppStorage 默认 true 一致）。
    /// 用 `object(forKey:)` 而不是 `bool(forKey:)`：后者在键不存在时也返回 false，会把默认自动误判成手动。
    static var autoLineEnabled: Bool {
        guard let raw = UserDefaults.standard.object(forKey: "apiAutoLine") else { return true }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        return true
    }

    /// 用户明确选择的线路（不经失败降权）。默认 `direct`（2026-11-24 恢复直连）。
    /// 注意老用户本地可能存着 "bj"，那沿用其选择；只有从未选过的用户才默认直连。
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

    /// 一次性迁移（2026-11-24 恢复直连）：老用户本地 `apiLineId` 存着 "bj"，
    /// 失败集里可能还留着 "direct"（上次删线前的 SSL 失败标记）——不处理就永远走不到
    /// 刚恢复的直连。这里重置为直连并清掉其失败标记；只做一次，之后用户在服务器状态页
    /// 手动选过就尊重其选择。
    private static let directRestoreKey = "apiDirectRestored20261124"
    static func migrateToDirectIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: directRestoreKey) else { return }
        d.set(true, forKey: directRestoreKey)
        d.set("direct", forKey: activeKey)
        clearLineFailed("direct")
        Self.session = makeSession(for: activeLine)
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

    /// 所有请求的唯一入口。记录本次耗时，满足「连续慢 / 线路繁忙」时按最佳候选自动换线。
    /// 换线逻辑在 `noteRequestDuration` 里，仅在自动模式下生效，且不动 `apiAutoLine`。
    static func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil,
        account: String? = nil
    ) async throws -> [String: Any] {
        let started = Date()
        do {
            let json = try await performRequest(
                path, method: method, body: body, token: token, account: account)
            await noteRequestDuration(Date().timeIntervalSince(started))
            return json
        } catch {
            await noteRequestDuration(Date().timeIntervalSince(started))
            throw error
        }
    }

    /// 真正的请求体（回落循环）。从原 `request` 原样拆出，便于外层统一计时。
    private static func performRequest(
        _ path: String,
        method: String,
        body: [String: Any]?,
        token: String?,
        account: String?
    ) async throws -> [String: Any] {
        // 默认走「自动回落」：按 orderedLines 逐条试，
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

    /// 记录一次请求耗时并按需触发自动换线检查。
    /// 触发条件（任一，且仅自动模式）：连续 2 次 > 3000ms，或当前线路最近一次 busy=true。
    private static func noteRequestDuration(_ seconds: TimeInterval) async {
        if Int(seconds * 1000) > slowThresholdMs {
            slowStreak += 1
        } else {
            slowStreak = 0
        }
        guard slowStreak >= 2 || AevisHosts.isBusy(currentLine.id) else { return }
        await autoSwitchIfNeeded()
    }

    /// 自动换线：实时探当前线路与候选，满足条件时切到 RTT 至少快 20% 的非繁忙线路。
    /// 60 秒冷却；内部换线绝不把 `apiAutoLine` 关掉（只有用户手动选线/自动选择才会改它）。
    private static func autoSwitchIfNeeded() async {
        guard autoLineEnabled, !autoSwitching else { return }
        if let last = lastAutoSwitchAt,
           Date().timeIntervalSince(last) < autoSwitchCooldown { return }
        autoSwitching = true
        defer { autoSwitching = false }

        let current = currentLine
        guard !current.base.isEmpty else { return }
        let candidates = lines.filter { !$0.base.isEmpty && $0.id != current.id }
        guard !candidates.isEmpty else { return }

        // 当前 + 候选一起探：结果写进 AevisHosts.pingState，排序 / 状态页 / 换线共用
        await AevisHosts.probeAndRecord([current] + candidates)
        let currentBusy = AevisHosts.isBusy(current.id)
        guard currentBusy || slowStreak >= 2 else { return }
        guard let currentRTT = AevisHosts.latency(current.id), currentRTT > 0 else { return }
        guard let best = AevisHosts.bestCandidate(excluding: current.id) else { return }
        guard Double(best.rtt) <= Double(currentRTT) * minRTTImprovement else { return }

        setActiveLine(best.line.id)
        lastAutoSwitchAt = Date()
        slowStreak = 0
        lastSwitchNote = "已自动切换到 \(best.line.name)"
        NSLog("[AutoLine] 换线：\(currentRTT)ms -> \(best.line.name) \(best.rtt)ms")
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

    // MARK: - 统一硬缓存（2.8）
    //
    // 用户诉求：「所有东西都要硬缓存，就算不点开也要用硬缓存抵上，服务器太拉了」。
    // 原则：**先读盘渲染 → 后台刷新 → 失败留旧值**。缓存不产生数据，只保存服务端给过的东西；
    // 任何解析函数都吃 `[String: Any]`，所以缓存命中与网络命中走的是同一段解析代码。

    /// 用户态缓存作用域：与 `Session.applyLogin` 写的 email 键一致。
    /// 不用 token —— token 会轮换，一换就读不到上次缓存；email 在设备上是稳定的。
    static var cacheScope: String {
        UserDefaults.standard.string(forKey: "email") ?? ""
    }

    /// 同步读缓存，给 View 在 `.onAppear` 里立刻种 state，不等网络。
    static func cachedJSON(_ key: HardCache.Key, scope: String = "") -> [String: Any]? {
        HardCache.cachedJSON(key, scope: scope)
    }

    /// stale-while-revalidate：TTL 内直接返回；过期先打网，打不通就退回旧缓存。
    /// 注意这个函数仍然 `async`——它用于「后台刷新」那一步；界面首帧请用 `cachedJSON`。
    static func cacheAndFetch(
        _ key: HardCache.Key,
        path: String,
        scope: String = "",
        ttl: TimeInterval = 300,
        token: String? = nil,
        account: String? = nil
    ) async throws -> [String: Any] {
        if HardCache.isFresh(key, scope: scope, ttl: ttl),
           let hit = HardCache.cachedJSON(key, scope: scope) {
            return hit
        }
        do {
            let json = try await request(path, token: token, account: account)
            HardCache.saveJSON(key, json, scope: scope)
            return json
        } catch {
            if let stale = HardCache.cachedJSON(key, scope: scope) {
                NSLog("[HardCache] \(key.rawValue) 刷新失败，用旧缓存：\(error.localizedDescription)")
                return stale
            }
            throw error
        }
    }

    /// 媒体资源 session：自签「直连」必须带 PinDelegate。
    /// 头像 / 广场封面之前用 `URLSession.shared` 或 `AsyncImage`，在这个 host 上必定 SSL 失败，
    /// 这就是用户说的「头像加载不出来、广场东西下不了」。非直连线走 shared。
    static func mediaSession(for url: URL) -> URLSession {
        guard let host = url.host else { return .shared }
        for line in lines where line.pinning && !line.base.isEmpty {
            guard let base = URL(string: line.base), let baseHost = base.host else { continue }
            if host == baseHost && url.port == base.port { return makeSession(for: line) }
        }
        return .shared
    }

    /// 把相对媒体路径拼成当前线路绝对地址（广场 / 头像共用一个入口，避免各写各的漏斜杠）。
    static func mediaURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        let base = self.base
        return URL(string: raw.hasPrefix("/") ? base + raw : base + "/" + raw)
    }

    /// 登录后空闲预热：不等用户点开，把常用数据一次性拉回落盘。
    /// 每项独立吞错 —— 一个接口 4xx 不能让其它缓存全空。优先 `.utility`，不抢 UI 线程。
    static func preloadHardCache(token: String, email: String) async {
        let scope = email
        let jobs: [(HardCache.Key, String, String, TimeInterval, String?, String?)] = [
            (.appConfig, "/v1/app/config", "", 1800, nil, nil),
            (.squarePersonas, "/v1/psquare/list", "", 1800, nil, nil),
            (.emojiPacks, "/v1/emoji/list", "", 1800, token, nil),
            (.pointPackages, "/v1/points/recharge/packages", "", 1800, nil, nil),
            (.shopProducts, "/v1/shop/products", "", 1800, nil, nil),
            (.quotaState, "/v1/quota/state", scope, 300, token, nil),
            (.pointsHome, "/v1/points", scope, 300, token, nil),
            (.usesBalance, "/v1/shop/ds-uses", scope, 300, token, nil),
            (.memberState, "/v1/me", scope, 300, token, nil),
            (.payMethods, "/v1/pay/methods", scope, 1800, token, nil),
        ]
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    _ = try? await cacheAndFetch(
                        job.0, path: job.1, scope: job.2,
                        ttl: job.3, token: job.4, account: job.5)
                }
            }
            for await _ in group { }
        }
        HardCache.cleanup()
        NSLog("[HardCache] preload done, scope=\(scope)")
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

    /// 更新资料（昵称 / 头像）。后端 `POST /v1/me/profile`，body 字段 `nickname` / `avatar`。
    ///
    /// `avatar` 传的是**服务端相对路径**（`/static/upload/xxx.jpg`），不是本地文件路径 ——
    /// 先走 `uploadImage(token:data:filename:)` 拿到路径，再调这里写回用户资料。
    /// 两个参数都是可选：只改头像时 nickname 传 nil，服务端保持原值。
    @discardableResult
    static func updateProfile(
        token: String,
        nickname: String? = nil,
        avatar: String? = nil
    ) async throws -> [String: Any] {
        var body: [String: Any] = [:]
        if let nickname { body["nickname"] = nickname }
        if let avatar { body["avatar"] = avatar }
        guard !body.isEmpty else { throw APIError.decode("没有要更新的字段") }
        return try await request("/v1/me/profile", method: "POST", body: body, token: token)
    }

    // MARK: - 角色

    static func myPersonas(token: String, email: String) async throws -> [Persona] {
        let json = try await request("/v1/psquare/mine", token: token, account: email)
        let data = (json["data"] as? [String: Any]) ?? json
        let rows = (data["rows"] as? [[String: Any]]) ?? (data["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { Persona(json: $0) }
    }

    /// 人设广场条目（对齐 `GET /v1/psquare/list` 的 data.rows[]）。
    /// 该接口公开，返回 published/listing 的人设，最多 200 条；不上报 X-Account 也能看。
    struct SquarePersona: Identifiable, Codable {
        let id: String
        let name: String
        let tagline: String
        let avatar: String
        let cover: String
        let adoptCount: Int
        let isOfficial: Bool
    }

    static func squarePersonas() async throws -> [SquarePersona] {
        let json = try await cacheAndFetch(.squarePersonas, path: "/v1/psquare/list", ttl: 1800)
        return parseSquarePersonas(json)
    }

    /// 解析函数单独暴露：View 首帧可以用 `cachedJSON(.squarePersonas)` 同步种 state。
    static func parseSquarePersonas(_ json: [String: Any]) -> [SquarePersona] {
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["rows"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = r["id"] as? String, !id.isEmpty else { return nil }
            return SquarePersona(
                id: id,
                name: (r["name"] as? String) ?? "未命名人设",
                tagline: (r["tagline"] as? String) ?? (r["personality"] as? String) ?? "",
                avatar: (r["avatar_url"] as? String) ?? (r["avatar"] as? String) ?? "",
                cover: (r["cover_url"] as? String) ?? (r["cover"] as? String) ?? "",
                adoptCount: (r["adopt_count"] as? NSNumber)?.intValue ?? 0,
                isOfficial: (r["is_official"] as? NSNumber)?.intValue == 1
            )
        }
    }

    /// 创建人设并投稿广场。后端 `POST /v1/psquare/publish` 已存在（需 X-Account）：
    /// AI 审核通过 → status="listing"（广场可见、非推荐位）；未过 → "rejected" + reason。
    struct PersonaCreateResult {
        let id: String
        let status: String
        let reason: String
        var listed: Bool { status == "listing" || status == "published" }
    }

    static func createPersona(
        name: String,
        tagline: String,
        personality: String,
        avatarURL: String,
        account: String
    ) async throws -> PersonaCreateResult {
        let json = try await request(
            "/v1/psquare/publish", method: "POST",
            body: [
                "name": name,
                "tagline": tagline,
                "personality": personality,
                "avatar_url": avatarURL,
                "relation": "lover"
            ],
            account: account
        )
        let d = (json["data"] as? [String: Any]) ?? json
        return PersonaCreateResult(
            id: (d["id"] as? String) ?? "",
            status: (d["status"] as? String) ?? "",
            reason: (d["reason"] as? String) ?? (json["msg"] as? String) ?? ""
        )
    }

    /// 采用（喜欢）广场人设：返回最新 adoptCount。
    /// 必须带 token：后端要据此把「我采用的」写进人设库，否则只加计数、进不了聊天列表。
    @discardableResult
    static func adoptPersona(id: String, token: String? = nil) async throws -> Int {
        let json = try await request(
            "/v1/psquare/adopt", method: "POST", body: ["id": id], token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return (d["adoptCount"] as? NSNumber)?.intValue ?? 0
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
        // 线路回落：按 orderedLines（直连→北京）逐条试，线路级错误才换线。
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
        try await cacheAndFetch(.appConfig, path: "/v1/app/config", ttl: 1800)
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
        var listPriceCents: Int = 0
        var listPriceYuan: String = ""
        var originalPriceCents: Int = 0
        var discountPercent: Int = 100
        var id: String { code }
    }

    /// 充值档位列表（公开接口，不需登录即可展示价格）。顶层 `items`。
    static func pointPackages() async throws -> [PointPackage] {
        let json = try await cacheAndFetch(
            .pointPackages, path: "/v1/points/recharge/packages", ttl: 1800)
        return parsePointPackages(json)
    }

    static func parsePointPackages(_ json: [String: Any]) -> [PointPackage] {
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
                pointsText: (r["pointsText"] as? String) ?? "",
                listPriceCents: (r["listPriceCents"] as? NSNumber)?.intValue ?? cents,
                listPriceYuan: (r["listPriceYuan"] as? String) ?? String(format: "¥%.2f", Double(cents) / 100),
                originalPriceCents: (r["originalPriceCents"] as? NSNumber)?.intValue ?? cents,
                discountPercent: (r["discountPercent"] as? NSNumber)?.intValue ?? 100
            )
        }
    }

    /// 墨点余额（需登录）。取不到时调用方显示「—」，不要显示 0。
    static func pointsBalance(token: String?) async throws -> Int {
        let json = try await cacheAndFetch(
            .pointsHome, path: "/v1/points", scope: cacheScope, ttl: 300, token: token)
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
        /// 本周剩余额度折成「还能聊多少条」（服务端 `est_messages`，2026-11-25 上线）。
        ///
        /// 这个字段存在的原因：旧口径拿 `points.est_messages`（墨点余额 ÷ 均价）当条数，
        /// 免费用户余额是 0 → 首页恒显示「您大约还有 0 条消息额度」，
        /// 可他明明还有整周的免费额度。`0` 表示服务端没给（或确实归零），
        /// 调用方据此回落到「免费基线 × 剩余百分比」。
        let estMessages: Int
        /// 剩余额度折成的 token 当量（2026-11-27 上线，`tokens_left`）。
        /// 用户口径是「额度按 token 讲」，所以首页主文案优先用它；0 = 服务端没给。
        let tokensLeft: Int
        /// 买断额度包还剩百分之几（`pack_pct`，没买过包时为 0）。
        let packPct: Int
        /// 重置时刻（ISO-8601 字符串）。服务端未下发时为 nil —— 主页不显示「重置」那一行，
        /// 不写死、不自己编日期。
        let resetAt: String?
    }

    /// 免费用户默认可聊条数。产品口径「约 14、15 条」取 15；改这里即可配置。
    /// 这是产品常量（不是服务端返回值），断网时也能展示基线。
    static let freeMessageBaseline = 15

    static func quotaState(token: String?) async throws -> QuotaState {
        let json = try await cacheAndFetch(
            .quotaState, path: "/v1/quota/state", scope: cacheScope, ttl: 300, token: token)
        return parseQuotaState(json)
    }

    static func parseQuotaState(_ json: [String: Any]) -> QuotaState {
        // 外层信封 {"code":200,"data":{...}} 已被 request 摊平到顶层，两种结构都兜一下
        let d = (json["data"] as? [String: Any]) ?? json
        let q = (d["quota"] as? [String: Any]) ?? (json["quota"] as? [String: Any]) ?? d
        return QuotaState(
            active: (q["active"] as? Bool) ?? false,
            percent: (q["percent"] as? NSNumber)?.intValue ?? 0,
            leftPct: (q["left_pct"] as? NSNumber)?.intValue ?? 0,
            hasQuota: (q["has_quota"] as? Bool) ?? false,
            // 2026-11-25：服务端 `est_messages`。没这个字段的老版本服务端按 0 处理，
            // 由 HomeView 回落到「免费基线 × 剩余百分比」。
            estMessages: (q["est_messages"] as? NSNumber)?.intValue
                ?? (d["est_messages"] as? NSNumber)?.intValue ?? 0,
            tokensLeft: (q["tokens_left"] as? NSNumber)?.intValue
                ?? (d["tokens_left"] as? NSNumber)?.intValue ?? 0,
            packPct: (q["pack_pct"] as? NSNumber)?.intValue
                ?? (d["pack_pct"] as? NSNumber)?.intValue ?? 0,
            resetAt: (q["reset_at"] as? String) ?? (q["resetAt"] as? String)
                ?? (q["next_reset"] as? String) ?? (d["reset_at"] as? String)
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
        let json = try await cacheAndFetch(
            .pointsHome, path: "/v1/points", scope: cacheScope, ttl: 300, token: token)
        return parsePointsHome(json)
    }

    static func parsePointsHome(_ json: [String: Any]) -> PointsHome {
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

    // MARK: - 天气（主页问候用；默认按定位坐标，失败回落南昌）

    struct WeatherNow {
        let tempC: Int
        let descCN: String   // 中文描述；映射不到就保留英文原文
        let place: String    // 城市名（wttr.in 的 nearest_area）；南昌兜底时为「南昌」，可能为空
    }

    /// 缓存有效期 10 分钟
    private static let weatherTTL: TimeInterval = 600

    /// 按坐标查天气（主路径）。wttr.in 支持 `/{lat},{lon}?format=j1`。
    /// - 坐标保留 3 位小数拼 URL（≈100m，足够选城市），缓存 key 只用 2 位（≈1km）：
    ///   定位稍有漂移不会重复请求，真换城市 key 就变、旧缓存自动失效；
    /// - 坐标**只**在本地拼 URL 和当缓存 key，不上传我们自己的服务端，也不落其它持久化字段。
    static func weather(lat: Double, lon: Double, force: Bool = false) async throws -> WeatherNow {
        let cacheKey = String(format: "%.2f,%.2f", lat, lon)
        let query = String(format: "%.3f,%.3f", lat, lon)
        return try await fetchWeather(query: query, cacheKey: cacheKey, placeFallback: "", force: force)
    }

    /// 南昌兜底：定位被拒 / 超时 / 定位失败 / 按坐标查天气失败时用，行为与旧版一致。
    static func weatherNanchang(force: Bool = false) async throws -> WeatherNow {
        try await fetchWeather(query: "Nanchang", cacheKey: "nanchang", placeFallback: "南昌", force: force)
    }

    /// 天气请求主体：3 秒超时、10 分钟 UserDefaults 缓存、解析 temp_C / weatherDesc / nearest_area。
    /// 失败直接抛错，由调用方决定「不显示」——**绝不返回假数据**。
    /// ATS：wttr.in 是标准 HTTPS 证书，不需要动 Info.plist；不走 APIClient 的线路回落。
    private static func fetchWeather(
        query: String,
        cacheKey: String,
        placeFallback: String,
        force: Bool
    ) async throws -> WeatherNow {
        let d = UserDefaults.standard
        let key = "aevis.weather.v2." + cacheKey
        let atKey = key + ".at"

        if !force {
            let at = d.double(forKey: atKey)
            if at > 0, Date().timeIntervalSince1970 - at < weatherTTL,
               let cached = d.dictionary(forKey: key),
               let t = cached["temp"] as? Int,
               let desc = cached["desc"] as? String, !desc.isEmpty {
                let place = (cached["place"] as? String) ?? placeFallback
                return WeatherNow(tempC: t, descCN: desc, place: place)
            }
        }

        guard let url = URL(string: "https://wttr.in/\(query)?format=j1") else {
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

        // 城市名：nearest_area[0].areaName[0].value（按坐标查时就是用户所在城市）
        let area = (json["nearest_area"] as? [[String: Any]])?.first
        let areaName = ((area?["areaName"] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        let w = WeatherNow(
            tempC: temp,
            descCN: cnWeather(en),
            place: areaName.isEmpty ? placeFallback : areaName
        )

        d.set(["temp": w.tempC, "desc": w.descCN, "place": w.place], forKey: key)
        d.set(Date().timeIntervalSince1970, forKey: atKey)
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
        // 2026-11-24 后端新增：商品类型（member/uses）、面价、权益服务端下发
        var kind: String = "member"
        var uses: Int = 0
        var listPriceCents: Int = 0
        var discountPercent: Int = 100
        var benefits: [String] = []
        var grantPoints: Int = 0
        var freeMinutes: Int = 0
        var signinBonus: Int = 0
        var checkinBonusMultiplier: Int = 0
        var usesPerYuan: Int = 0
        var minSellUses: Int = 0
        /// 聊天额度包到账额度点数（kind == "quota" 时有效）
        var points: Int = 0
        /// 额度包折算的可聊条数（服务端按实际均价算，端上别自己除法）
        var estMessages: Int = 0
        /// 额度包折算的 token 当量（2026-11-27：额度按 token 讲，不再讲条数）
        var tokensTotal: Int = 0
        var chargeModels: [String] = []
        /// DeepSeek 按次 token 上限：{model: ["max_tokens": n, "input_chars": n]}
        var tokenCaps: [String: [String: Any]] = [:]
    }

    /// 会员套餐列表（公开接口）。顶层 `items`。
    static func shopProducts() async throws -> [ShopProduct] {
        let json = try await cacheAndFetch(.shopProducts, path: "/v1/shop/products", ttl: 1800)
        return parseShopProducts(json)
    }

    static func parseShopProducts(_ json: [String: Any]) -> [ShopProduct] {
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
                label: (r["label"] as? String) ?? "",
                kind: (r["kind"] as? String) ?? "member",
                uses: (r["uses"] as? NSNumber)?.intValue ?? 0,
                listPriceCents: (r["list_price_cents"] as? NSNumber)?.intValue ?? 0,
                discountPercent: (r["discount_percent"] as? NSNumber)?.intValue ?? 100,
                benefits: (r["benefits"] as? [String]) ?? [],
                grantPoints: (r["grant_points"] as? NSNumber)?.intValue ?? 0,
                freeMinutes: (r["free_minutes"] as? NSNumber)?.intValue ?? 0,
                signinBonus: (r["signin_bonus"] as? NSNumber)?.intValue ?? 0,
                checkinBonusMultiplier: (r["checkin_bonus_multiplier"] as? NSNumber)?.intValue ?? 0,
                usesPerYuan: (r["uses_per_yuan"] as? NSNumber)?.intValue ?? 0,
                minSellUses: (r["min_sell_uses"] as? NSNumber)?.intValue ?? 0,
                // 额度包：服务端下发 points，老服务端只给 grant_points，两个都认
                points: (r["points"] as? NSNumber)?.intValue
                    ?? (r["grant_points"] as? NSNumber)?.intValue ?? 0,
                estMessages: (r["est_messages"] as? NSNumber)?.intValue ?? 0,
                tokensTotal: (r["tokens_total"] as? NSNumber)?.intValue ?? 0,
                chargeModels: (r["charge_models"] as? [String]) ?? [],
                tokenCaps: (r["token_caps"] as? [String: [String: Any]]) ?? [:]
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
        let payURL: String       // 易支付收银台地址（老服务端 / 兜底二维码内容）
        let kind: Kind
        /// 2.8 聚合短链：`https://aevis.cn/prod-api/aevis/v1/shop/paylink/<订单号>`，
        /// 按扫码 App 的 UA 自动跳微信或支付宝。空串 = 老服务端还没下发。
        var payLink: String = ""
        var uses: Int = 0        // 按次订单：购买的次数（后端 order 响应新增）
        var id: String { kind.rawValue + "-" + orderID }

        /// 二维码真正编码的内容：有聚合短链就用它，否则回落收银台地址。
        var qrContent: String { payLink.isEmpty ? payURL : payLink }
        var hasAggregateLink: Bool { !payLink.isEmpty }
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
        return PayOrder(
            orderID: no,
            payURL: (d["payUrl"] as? String) ?? "",
            kind: .points,
            payLink: (d["pay_link"] as? String) ?? (d["payLink"] as? String) ?? ""
        )
    }

    /// 墨点查单：state == "paid" 即到账，points 为到账墨点数。
    static func pointsOrderStatus(orderNo: String, token: String) async throws -> (paid: Bool, points: Int) {
        let enc = orderNo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderNo
        let scope = "points:\(orderNo)"
        do {
            let json = try await request("/v1/points/recharge/\(enc)", token: token)
            let d = (json["data"] as? [String: Any]) ?? json
            let result = ((d["state"] as? String) == "paid",
                          (d["points"] as? NSNumber)?.intValue ?? 0)
            // 2.8：最后一次查单结果落盘。支付完成瞬间网络抖一下也不能把已付订单显示成未付。
            HardCache.saveJSON(.payOrder, ["paid": result.0, "points": result.1], scope: scope)
            return result
        } catch {
            if let cached = HardCache.cachedJSON(.payOrder, scope: scope) {
                return ((cached["paid"] as? Bool) ?? false,
                        (cached["points"] as? NSNumber)?.intValue ?? 0)
            }
            throw error
        }
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
        return PayOrder(
            orderID: oid,
            payURL: (d["pay_url"] as? String) ?? "",
            kind: .member,
            payLink: (d["pay_link"] as? String) ?? (d["payLink"] as? String) ?? "",
            uses: (d["uses"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// 按次余额：`GET /v1/shop/ds-uses` → data.balance.uses_left
    struct UsesBalance {
        let total: Int
        let left: Int
        let used: Int
    }
    static func dsUses(token: String) async throws -> UsesBalance {
        let json = try await cacheAndFetch(
            .usesBalance, path: "/v1/shop/ds-uses", scope: cacheScope, ttl: 300, token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        let b = (d["balance"] as? [String: Any]) ?? [:]
        return UsesBalance(
            total: (b["uses_total"] as? NSNumber)?.intValue ?? 0,
            left: (b["uses_left"] as? NSNumber)?.intValue ?? 0,
            used: (b["uses_used"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// 按次订单查单（复用 /v1/shop/orders/<id>）：state=paid 且 uses>0 即到账。
    static func usesOrderStatus(orderID: String, token: String) async throws -> (paid: Bool, uses: Int) {
        let enc = orderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderID
        let json = try await request("/v1/shop/orders/\(enc)", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return ((d["state"] as? String) == "paid",
                (d["uses"] as? NSNumber)?.intValue ?? 0)
    }

    /// 会员查单：state == "paid" 即到账，days 为到账天数。
    static func memberOrderStatus(orderID: String, token: String) async throws -> (paid: Bool, days: Int) {        let enc = orderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderID
        let scope = "member:\(orderID)"
        do {
            let json = try await request("/v1/shop/orders/\(enc)", token: token)
            let d = (json["data"] as? [String: Any]) ?? json
            let result = ((d["state"] as? String) == "paid",
                          (d["days"] as? NSNumber)?.intValue ?? 0)
            HardCache.saveJSON(.payOrder, ["paid": result.0, "days": result.1], scope: scope)
            return result
        } catch {
            if let cached = HardCache.cachedJSON(.payOrder, scope: scope) {
                return ((cached["paid"] as? Bool) ?? false,
                        (cached["days"] as? NSNumber)?.intValue ?? 0)
            }
            throw error
        }
    }

    /// 聊天额度包查单：state == "paid" 即到账，points 为实际到账墨点。
    /// 走同一个 `/v1/shop/orders/<id>`，只是取 grant_points 而不是 days —— 额度包不加会员天数。
    static func quotaOrderStatus(orderID: String, token: String) async throws -> (paid: Bool, points: Int) {
        let enc = orderID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orderID
        let json = try await request("/v1/shop/orders/\(enc)", token: token)
        let d = (json["data"] as? [String: Any]) ?? json
        return ((d["state"] as? String) == "paid",
                (d["grant_points"] as? NSNumber)?.intValue ?? 0)
    }

    /// 会员剩余天数（从 /v1/me 容错解析 membership.days_left；读不到返回 nil，界面显示占位）。
    static func membershipDays(token: String) async throws -> Int? {
        let json = try await cacheAndFetch(
            .memberState, path: "/v1/me", scope: cacheScope, ttl: 300, token: token)
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
        /// 预计每条消息扣多少墨点（服务端 `estPointsPerMsg`，2026-11-25 上线）。
        ///
        /// 公式与首页 `avg_msg_cost` 完全一致（4000 输入 + 500 输出），所以
        /// 「这里显示的单价 × 剩余条数」和首页「还能聊几条」能对上，不会自相矛盾。
        /// **0 = 老服务端没下发这个字段**，此时不显示价格（不显示「0 墨点」）。
        let estPointsPerMsg: Double

        /// 单条价格高于这个值就标警示色。
        /// 依据：同组价差能到 72 倍（deepseek-web 0.1 / kimi-k2.6 7.27），
        /// 用户点选前必须能一眼看出「这个贵」。阈值只在这里定义，别在页面里再写一次。
        static let priceyThreshold: Double = 3.0

        /// 计费方式的中文短标（给选择列表用）。
        var billingText: String {
            switch billing {
            case "per_token": return "按 token"
            case "per_call":  return "按次"
            default:          return billing.isEmpty ? "" : billing
            }
        }

        /// 列表里展示的「计费方式 · 单价」。
        /// 有价：`按次 · 7.3 墨点/条` / `按 token · 约 0.9 墨点/条`；无价：只显示计费方式。
        var priceText: String {
            guard estPointsPerMsg > 0 else { return billingText }
            let n = Self.formatPoints(estPointsPerMsg)
            // 按 token 是估算，加「约」；按次是固定扣，不加
            let prefix = billing == "per_token" ? "约 " : ""
            return "\(billingText) · \(prefix)\(n) 墨点/条"
        }

        /// 是否属于「贵」的那一档（用于警示配色）。
        var isPricey: Bool { estPointsPerMsg > Self.priceyThreshold }

        /// 墨点单价格式：<10 保留 1 位（7.3 / 0.9），≥10 取整（24 / 50）。
        /// 价差跨两个数量级，统一 `%.1f` 会让 50.6 和 0.9 一样长，反而不好扫。
        static func formatPoints(_ v: Double) -> String {
            if v >= 10 { return String(format: "%.0f", v) }
            if v >= 1 { return String(format: "%.1f", v) }
            return String(format: "%.2f", v).replacingOccurrences(of: "0$", with: "", options: .regularExpression)
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
                isDefault: (r["default"] as? Bool) ?? (id == defaultID),
                // 老服务端没有这个字段 → 0 → 列表里不显示价格，不报错、不显示 0
                estPointsPerMsg: (r["estPointsPerMsg"] as? NSNumber)?.doubleValue
                    ?? (r["perCallPoints"] as? NSNumber)?.doubleValue ?? 0
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

    /// 表情包广场条目（对齐 `GET /v1/emoji/list` 的 data.rows[]）。
    /// items 是图片相对/绝对 URL 数组；接口只返回 status=published，按 use_count 排序。
    struct EmojiPack: Identifiable, Codable {
        let id: String
        let name: String
        let intro: String
        let cover: String
        let useCount: Int
        let items: [String]
        var count: Int { items.count }
    }

    static func emojiPacks(token: String?) async throws -> [EmojiPack] {
        let json = try await cacheAndFetch(
            .emojiPacks, path: "/v1/emoji/list", ttl: 1800, token: token)
        return parseEmojiPacks(json)
    }

    static func parseEmojiPacks(_ json: [String: Any]) -> [EmojiPack] {
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["rows"] as? [[String: Any]]) ?? (d["items"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            let ident: String
            if let s = r["id"] as? String, !s.isEmpty { ident = s }
            else if let n = r["id"] as? NSNumber { ident = n.stringValue }
            else { return nil }
            let urls = (r["items"] as? [String]) ?? []
            return EmojiPack(
                id: ident,
                name: (r["name"] as? String) ?? "未命名表情包",
                intro: (r["intro"] as? String) ?? "",
                cover: (r["cover_url"] as? String) ?? (urls.first ?? ""),
                useCount: (r["use_count"] as? NSNumber)?.intValue ?? 0,
                items: urls
            )
        }
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

    /// 在**指定线路**上裸发一次 GET：不走回落、不读 `lines`、不递归。
    ///
    /// 给 `AevisHosts` 拉 `/v1/app/config` 和测 `/v1/ping` 用 —— 那个时刻线路表本身还没定，
    /// 走 `request` 会 `lines` → `allAccountLines` → 又回来拉配置，成环。
    /// 返回 `(data, httpStatus)`；连接失败/超时返回 nil（与「返回了 4xx/5xx」区分开）。
    static func rawGet(_ path: String, line: Line,
                       timeout: TimeInterval = 4) async -> (data: Data, status: Int)? {
        guard !line.base.isEmpty, let url = URL(string: line.base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await makeSession(for: line).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return (data, code)
        } catch {
            return nil
        }
    }

    /// 一次 `/v1/ping` 实测，同时拿 RTT（毫秒）与 `data.busy`。不可达返回 nil。
    ///
    /// 判定口径（2026-11-25，别改）：
    /// - **2xx/3xx → 可达**
    /// - **429 / 503 → 可达，照常计入 RTT**：被 nginx `limit_req` 限流不等于线路挂了。
    ///   只认 2xx 的话，「限流」会被误判成「线路不可用」，然后把整条线路从候选里剔掉
    ///   —— 那是比误报更糟的连锁反应（本来只是慢，结果变成没得用）。
    /// - **超时 / 连接失败 / TLS 失败 → 不可达**
    /// - **404 及其它 4xx/5xx → 不可达**：与 `probe()` 保持一致 ——
    ///   「nginx 活着但没挂 API」是半死状态，不能当可用线路收进候选。
    ///
    /// `busy` 读不到时按 false 处理（负载字段缺失不能让探针失败）。
    static func pingInfo(_ line: Line, timeout: TimeInterval = 2) async -> (rtt: Int, busy: Bool)? {
        let t0 = Date()
        guard let r = await rawGet("/v1/ping", line: line, timeout: timeout) else { return nil }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard (200..<400).contains(r.status) || r.status == 429 || r.status == 503 else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any] ?? [:]
        let data = (json["data"] as? [String: Any]) ?? json
        let rawBusy = data["busy"] ?? json["busy"]
        var busy = false
        if let b = rawBusy as? Bool { busy = b }
        else if let n = rawBusy as? NSNumber { busy = n.boolValue }
        return (rtt: ms, busy: busy)
    }

    /// 一次 `/v1/ping` 实测（毫秒）；不可达返回 nil。给 `AevisHosts` 排线路用。
    ///
    /// 保留原行为与方法名供其它调用点使用；内部复用 `pingInfo`，只取 RTT。
    static func pingLatency(_ line: Line, timeout: TimeInterval = 2) async -> Int? {
        (await pingInfo(line, timeout: timeout))?.rtt
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
                // 只认 2xx/3xx；404（"nginx 在但没挂 API"那种半死状态）以前被算成可用，
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
