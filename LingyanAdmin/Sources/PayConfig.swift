import Foundation

/// 码支付后台（payadmin）的地址 + 登录态。
///
/// ⚠️ 和 `AppConfig` **故意完全分家**：两套 UserDefaults key、两个单例。
/// 因为它们压根是两台不同后端上的两套账号体系：
///   · 素材后台 = `POST /api/auth/login` → JWT（`Authorization: Bearer`）
///   · 码支付   = `POST /payadmin/api/login` → 自签令牌（`X-Pay-Token`）
/// 合成一个的话，一边退出登录会把另一边一起踢掉；而且一边的令牌在另一边
/// 永远是 401，看起来就像「App 坏了」。
final class PayConfig: ObservableObject {
    static let shared = PayConfig()

    /// 码支付后台挂在 nginx 的 `/payadmin/` 子路径下。
    ///
    /// ⚠️ 前缀**必须保留**：nginx 里那条是 `proxy_pass http://127.0.0.1:8792;`
    ///    （不带 URI = 保留前缀），所以真实接口是 `/payadmin/api/xxx`。
    ///    而 paymon/xzb 那几条是 `proxy_pass .../;`（带 URI = 剥掉前缀）——
    ///    **差一个斜杠，全废**。填地址时别自作聪明去掉 `/payadmin`。
    static let defaultServer = "https://lingyan.cyou/payadmin"
    /// 备用入口（香港**同一台机器、同一个库**的 443 入口）。
    static let backupServer = "https://sucai.lingyan.cyou/payadmin"

    @Published var server: String
    @Published var username: String
    /// 登录令牌。空 = 没登录，界面会回到这一侧的登录页。
    @Published private(set) var token: String

    private let store = UserDefaults.standard
    private static let kServer = "ly_pay_server"
    private static let kUser = "ly_pay_user"
    private static let kToken = "ly_pay_token"

    private init() {
        let args = ProcessInfo.processInfo.arguments

        if let i = args.firstIndex(of: "-payserver"), i + 1 < args.count {
            server = args[i + 1]
        } else {
            server = store.string(forKey: Self.kServer) ?? Self.defaultServer
        }
        username = store.string(forKey: Self.kUser) ?? ""
        token = store.string(forKey: Self.kToken) ?? ""

        // 截图自检：`-demo` 全走本地假数据、一个网络请求都不发。
        if AppConfig.isDemo {
            server = "demo"
            username = "零砚（演示）"
            token = "DEMO"
        }
        // `-showSetup` 强制显示登录页（跟 -demo 是一对开关，在 AppConfig 里定义的）。
        if AppConfig.forceSetup {
            server = Self.defaultServer
            username = ""
            token = ""
        }
    }

    /// 规范化用户填的地址：补协议、去尾斜杠，**缺 /payadmin 时补上**。
    static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return defaultServer }
        let lower = t.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            t = "https://" + t
        }
        while t.hasSuffix("/") { t.removeLast() }
        // 只填了域名（没有路径）→ 补 /payadmin。不然请求会打到素材后端的根上，
        // 返回的东西全对不上，排查起来要命。
        if let r = t.range(of: "://") {
            let hostAndPath = String(t[r.upperBound...])
            if !hostAndPath.contains("/") {
                t += "/payadmin"
            }
        }
        return t
    }

    var baseURL: String { PayConfig.normalize(server) }

    var configured: Bool {
        if AppConfig.forceSetup { return false }
        return !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 给界面看的短地址（去掉协议）
    var shortServer: String {
        var s = baseURL
        for p in ["https://", "http://"] where s.hasPrefix(p) {
            s.removeFirst(p.count)
        }
        return s
    }

    /// 登录成功后保存（密码不落盘）
    func save(server: String, user: String, token: String) {
        let s = PayConfig.normalize(server)
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = s
        self.username = u
        self.token = t
        store.set(s, forKey: Self.kServer)
        store.set(u, forKey: Self.kUser)
        store.set(t, forKey: Self.kToken)
    }

    /// 退出登录：清掉令牌（**账号名留着**，下次不用重新打）
    func signOut() {
        token = ""
        store.removeObject(forKey: Self.kToken)
    }
}
