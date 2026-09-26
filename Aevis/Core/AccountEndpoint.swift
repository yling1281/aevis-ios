import Foundation

/// 账号后端有**主域名 + 备用域名**两个，这里负责挑一个能通的。
///
/// 为什么非要有它：域名的拦截不是"全通或全断"，而是**按线路抽样**的 ——
/// `lingyan.cyou` 被阿里云按备案状态拦着，可有的线路照样能访问、有的只能看到拦截页；
/// 而 `sucai/account.apekin.com` 是已备案的新域名。
/// 写死任何一个都等于赌运气，所以开机探一次，谁通走谁，结果写进 `AppSettings.accountServerURL`。
///
/// ⚠️ 探测只看"能不能建立连接"，**不看返回码** —— 404/401 都算通：
///    能收到 HTTP 响应就说明域名解析、TLS、服务器都是活的，这已经是我们想知道的全部。
///    反过来，如果要求特定返回码，服务器一改接口这里就误判。
enum AccountEndpoint {

    private static let key = "aevis.account.resolvedBase"

    /// 上一次探测到的可用地址（跟机器走，不跨设备）。
    static var resolved: String? { UserDefaults.standard.string(forKey: key) }

    /// 现在走的是哪条线路（"线路一" / "线路二"）。没探过就是 nil。
    static var activeLineName: String? {
        guard let base = resolved, !base.isEmpty else { return nil }
        return AevisHosts.lineName(for: base)
    }

    /// 依次探测候选线路，返回第一个能通的，并记下来。
    /// 全都不通就返回线路一 —— 让上层照常报错，而不是在这里假装成功。
    @discardableResult
    static func refresh() async -> String {
        // 先用上次那条探一下：命中就不必再试别的，省一次请求
        if let cached = resolved, !cached.isEmpty, await reachable(cached) {
            return cached
        }
        for base in AevisHosts.accountCandidates where await reachable(base) {
            UserDefaults.standard.set(base, forKey: key)
            return base
        }
        return AevisHosts.accountBase
    }

    /// 手动指定一条线路（用户在图里点"线路二"那种），存下来并返回能不能通。
    @discardableResult
    static func use(_ base: String) async -> Bool {
        guard await reachable(base) else { return false }
        UserDefaults.standard.set(base, forKey: key)
        return true
    }

    /// 只判断"能不能连上"（HEAD，404/401 也算通）。
    /// **非 private** —— 管理端要复用同一套判断口径，两个 App 不能各判各的。
    static func reachable(_ base: String) async -> Bool {
        guard let url = URL(string: base + "/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }
}
