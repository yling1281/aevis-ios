import Foundation

/// 服务器地址 + 登录态的本地存储。
///
/// 2026-10-08 改版：原来靠一条 API Key（`X-API-Key`）看只读数据；
/// 现在「零砚后台」是**完整版后台**，改成和电脑网页后台一样的 **账号密码登录** ——
/// 登录后拿到 JWT 令牌（`Authorization: Bearer`），能看也能改。
/// API Key 那套留给**第三方**用（拿码 / 验证 / 上传文件），App 这边不再碰它。
///
/// ⚠️ 这个类**故意不加 `@MainActor`**：View 的属性初始化里会取 `.shared`，
///    加了隔离在 Swift 5 语言模式下会报「非隔离上下文访问主线程属性」。
///    调用点本来就都在主线程，不需要隔离。
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    /// 主入口（香港前置，nginx 在 8642 终结 TLS）
    static let defaultServer = "https://lingyan.cyou:8642"
    /// 备用入口（香港**同一台机器、同一个库**的 443 入口）。
    ///
    /// ⚠ 备地址绝不能指向别的机器：早先配的是「123.57.33.160 裸 IP」——那是另一台
    ///    机器上的旧快照（少一个用户、卡密/设备都是旧数据），回退过去会出现
    ///    「刚买的卡密验不过」。现在这条走 443，回的是同一台机器。
    static let backupServer = "https://sucai.lingyan.cyou"

    @Published var server: String
    @Published var username: String
    /// 「站长」/「管理员」/「普通账号」—— 只用来显示徽标，真实权限永远以服务器为准
    @Published var roleText: String
    /// 登录令牌（JWT）。空 = 没登录，界面会回到登录页。
    @Published private(set) var token: String

    private let store = UserDefaults.standard
    private static let kServer = "ly_server"
    private static let kUser = "ly_user"
    private static let kToken = "ly_token"
    private static let kRole = "ly_role"

    private init() {
        let args = ProcessInfo.processInfo.arguments

        if let i = args.firstIndex(of: "-server"), i + 1 < args.count {
            server = args[i + 1]                       // 截图自检用
        } else {
            server = store.string(forKey: Self.kServer) ?? Self.defaultServer
        }
        username = store.string(forKey: Self.kUser) ?? ""
        token = store.string(forKey: Self.kToken) ?? ""
        roleText = store.string(forKey: Self.kRole) ?? ""

        if AppConfig.isDemo {
            server = "demo"
            username = "零砚（演示）"
            roleText = "站长"
            token = "DEMO"
        }
        if args.contains("-showSetup") {
            // 截图自检要单独拍「登录」那一屏（跟 -demo 是一对开关）
            server = Self.defaultServer
            username = ""
            roleText = ""
            token = ""
        }
    }

    /// 演示/截图模式：全部走本地假数据，一个网络请求都不发。
    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    /// 强制显示登录页（截图用）
    static var forceSetup: Bool {
        ProcessInfo.processInfo.arguments.contains("-showSetup")
    }

    /// 截图自检要直接拍到某一页：`-tab 2`（0 起）
    static var demoInitialTab: Int {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-tab"), i + 1 < args.count, let n = Int(args[i + 1]) {
            return max(0, min(4, n))
        }
        return 0
    }

    /// 规范化用户填的地址：补协议、去尾斜杠
    static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return defaultServer }
        let lower = t.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            t = "https://" + t
        }
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    var baseURL: String { AppConfig.normalize(server) }

    var configured: Bool {
        if AppConfig.forceSetup { return false }
        return !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isOwner: Bool { roleText.contains("站长") }

    /// 给界面看的短地址（去掉协议）
    var shortServer: String {
        var s = baseURL
        for p in ["https://", "http://"] where s.hasPrefix(p) {
            s.removeFirst(p.count)
        }
        return s
    }

    /// 登录成功后保存
    func save(server: String, user: String, token: String, role: String) {
        let s = AppConfig.normalize(server)
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = s
        self.username = u
        self.token = t
        self.roleText = role
        store.set(s, forKey: Self.kServer)
        store.set(u, forKey: Self.kUser)
        store.set(t, forKey: Self.kToken)
        store.set(role, forKey: Self.kRole)
    }

    /// 只换服务器地址（保留登录态）
    func saveServer(_ raw: String) {
        let s = AppConfig.normalize(raw)
        server = s
        store.set(s, forKey: Self.kServer)
    }

    /// 退出登录：清掉令牌（**账号名留着**，下次登录不用重新打）
    func signOut() {
        token = ""
        store.removeObject(forKey: Self.kToken)
    }
}
