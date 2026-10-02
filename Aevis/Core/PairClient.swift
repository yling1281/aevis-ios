import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 手机端「扫码配对」的客户端 —— 生态第一期（D1）。
///
/// ## 它干什么
/// 电脑版（Unity）启动后出一张 `aevis://pair?...` 的码 → 这里扫到 → 解析 → 问用户
/// 「要用这台手机授权它登录吗」→ 同意 → `POST /pair/claim` → **电脑端当场收到
/// 「已授权」**，它就这么登进去了。
///
/// ## 三条硬口径（服务端也是照这个设计的，见 `deliverables/.../aevis-配对接口契约`）
/// 1. **服务器不知道聊天内容**：它只做「带授权的介绍」，之后只转发信封。
/// 2. ⚠️ **不上报 `accountToken`** —— 私服里没有账号库，发过去没人认，
///    白白多一条「本机凭据离机」的路。上报的是**身份快照**（设备码 / 名字 / 她叫什么），
///    只够让对方界面显示「是谁授权了我」，一个字不多。
/// 3. **没有域名也能用**：走 `http://<IP>:<端口>`；二维码是我们自己的串、不是网址
///    （App 自己解析，不需要浏览器能打开），明文 HTTP 也已在 `Info.plist` 里放开
///    （`NSAllowsArbitraryLoads`）。
enum PairClient {

    // MARK: - 类型

    /// 二维码里那张票。
    struct Ticket: Equatable, Identifiable {
        var host: String
        var port: Int
        var ticket: String
        var code: String
        var version: Int

        var id: String { ticket }
        var base: String { "http://\(host):\(port)" }
    }

    /// 认领成功的结果。
    struct Claim: Equatable {
        var session: String
        var already: Bool
        var pcName: String
        var pcOS: String
    }

    /// 一台已经配过的电脑。
    ///
    /// ⚠️ **只存在本机**。服务器上有个 `/pair/list`，但它要管理凭证 ——
    /// 那是给电脑上查状态用的，**不进 App**。手机上「配过哪几台」由本机自己记。
    struct PairedPC: Codable, Identifiable, Equatable {
        var session: String
        var name: String
        var os: String
        var at: Double

        var id: String { session }
    }

    enum Failure: LocalizedError {
        case notOurCode
        case wrongCode(left: Int)
        case noSuchCode
        case expired
        case outOfTries
        case throttled
        case unauthorized
        case badReply
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notOurCode:
                return "这个码不是 Aevis 的配对码。"
            case .wrongCode(let left):
                return left > 0
                    ? "配对码不对，还能再试 \(left) 次。"
                    : "配对码不对。"
            case .noSuchCode:
                return "没找到这个配对码 —— 可能输错了，也可能电脑上那张已经过期。"
            case .expired:
                return "这张配对码过期了。让电脑上刷新一张新的。"
            case .outOfTries:
                return "错太多次，这张码已经作废了。让电脑上刷新一张新的。"
            case .throttled:
                return "试得太频繁了，等一分钟再来。"
            case .unauthorized:
                return "配对服务不认这个客户端版本。可能要更新 App。"
            case .badReply:
                return "服务器回的东西看不懂。"
            case .network(let why):
                return "没连上配对服务器（\(why)）。"
            }
        }
    }

    // MARK: - 服务器地址

    /// 现在的配对服务器地址。
    ///
    /// 优先读**远端配置**里的 `pairBase` —— 换服务器不必重出包（跟 `accountBase` 一个套路）。
    /// 键名在 `AevisHosts.pairRemoteOverrideKey`，别在这儿写字面量。
    static var currentBase: String {
        let override = RemoteConfig.shared
            .string(AevisHosts.pairRemoteOverrideKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var base = override.isEmpty ? AevisHosts.pairBase : override
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    // MARK: - 解析二维码

    /// 认一段二维码文本。不是我们的码就返回 `nil`（**不抛错** —— 扫码器那边
    /// 只想知道"这是不是配对码"，拿异常当流程控制会让调用方到处都是 do/catch）。
    ///
    /// 串长这样：`aevis://pair?v=1&h=106.52.113.18&p=9100&t=<ticket>&c=<6位>`
    static func parse(_ text: String) -> Ticket? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 二维码里塞一个几 KB 的串再让我们解析，本身就是攻击面 —— 先卡长度
        guard !trimmed.isEmpty, trimmed.count <= 2048 else { return nil }
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        guard let comps = URLComponents(string: trimmed) else { return nil }

        var map: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            guard let value = item.value, !value.isEmpty else { continue }
            map[item.name] = value
        }

        guard let host = map["h"], !host.isEmpty,
              let portText = map["p"], let port = Int(portText),
              port > 0, port <= 65535,
              let ticket = map["t"], !ticket.isEmpty else { return nil }

        return Ticket(host: host, port: port, ticket: ticket,
                      code: map["c"] ?? "",
                      version: Int(map["v"] ?? "1") ?? 1)
    }

    /// 二维码串的前缀。**只有这一处**，改协议时别漏。
    static let prefix = "aevis://pair"

    // MARK: - 认领

    /// 认领配对。`ticket` 走扫码路，`code` 走手输路（两条都传就都校验）。
    static func claim(ticket: String?, code: String?, base: String) async throws -> Claim {
        guard let url = URL(string: base + "/pair/claim") else { throw Failure.badReply }

        var payload: [String: Any] = ["phone": identity()]
        if let ticket, !ticket.isEmpty { payload["ticket"] = ticket }
        if let code, !code.isEmpty { payload["code"] = code }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AevisHosts.pairClientToken, forHTTPHeaderField: "X-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.badReply }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if http.statusCode == 200 {
            guard let session = json["session"] as? String, !session.isEmpty else {
                throw Failure.badReply
            }
            let pc = json["pc"] as? [String: Any] ?? [:]
            let name = (pc["name"] as? String) ?? ""
            return Claim(session: session,
                         already: (json["already"] as? Bool) ?? false,
                         pcName: name.isEmpty ? "电脑" : name,
                         pcOS: (pc["os"] as? String) ?? "")
        }

        switch http.statusCode {
        case 401:
            throw Failure.unauthorized
        case 403:
            throw Failure.wrongCode(left: intValue(json["left"]))
        case 404:
            throw Failure.noSuchCode
        case 410:
            throw Failure.expired
        case 429:
            // 两种 429 意思完全不同：一个是"这张码废了"，一个是"你太快了"
            throw (json["error"] as? String) == "too many tries"
                ? Failure.outOfTries
                : Failure.throttled
        default:
            throw Failure.badReply
        }
    }

    /// 上报给服务器的**身份快照**。
    ///
    /// ⚠️ 这里**故意没有 `accountToken`** —— 见文件头第 2 条。
    /// 加字段之前先问一句：对面拿这个字段能干什么？答不上来就别加。
    static func identity() -> [String: String] {
        var out: [String: String] = [:]
        out["device"] = DeviceIdentity.wireCode
        out["persona"] = PersonaStore.shared.persona.name
        #if canImport(UIKit)
        out["device_name"] = UIDevice.current.name
        #endif
        let masked = AppSettings.shared.deviceAuthorizedAccount
        if !masked.isEmpty { out["account"] = masked }
        out["app"] = "aevis/" + appVersion
        return out
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - 本机记着「配过哪几台电脑」

    private static let storeKey = "aevis.pair.paired"

    static var paired: [PairedPC] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([PairedPC].self, from: data) else {
            return []
        }
        return list.sorted { $0.at > $1.at }
    }

    @discardableResult
    static func remember(session: String, pcName: String, pcOS: String) -> [PairedPC] {
        var list = paired.filter { $0.session != session }
        list.insert(PairedPC(session: session, name: pcName, os: pcOS,
                             at: Date().timeIntervalSince1970), at: 0)
        save(Array(list.prefix(20)))          // 最多记 20 台，别让它无限长
        return paired
    }

    @discardableResult
    static func forget(session: String) -> [PairedPC] {
        save(paired.filter { $0.session != session })
        return paired
    }

    private static func save(_ list: [PairedPC]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    /// 告诉服务器「这台不再配对了」。
    ///
    /// **不管服务器答不答应，本机都算解除** —— 用户按的是"不再配对"，
    /// 因为网络不好就继续把它列在那儿，才是更糟的事。
    static func revoke(session: String) async {
        guard let url = URL(string: currentBase + "/pair/revoke") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AevisHosts.pairClientToken, forHTTPHeaderField: "X-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["session": session])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 顺手探一下配对服务器通不通（卡片上"当前服务器"那行要用）。
    static func ping() async -> Bool {
        guard let url = URL(string: currentBase + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - 零件

    /// JSON 里的数字可能是 `Int` 也可能是 `NSNumber`（`JSONSerialization` 的脾气）——
    /// 两种都认。
    private static func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }
}
