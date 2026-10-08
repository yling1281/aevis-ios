import Foundation

/// 服务器地址 + API Key 的本地存储。
///
/// 为什么不把 Key 编译进包里：这个包是要发给别人装的，
/// 二进制里写死的 Key 谁都能扒出来。所以改成**首次打开自己填**，
/// 存在本机 UserDefaults 里；后台随时能停用某个 Key。
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
    /// ⚠️ 备地址绝不能指向别的机器：早先配的是「123.57.33.160 裸 IP」——那是另一台
    ///    机器上的旧快照（少一个用户、卡密/设备都是旧数据），回退过去会出现
    ///    「刚买的卡密验不过」。而且那个端口一直被安全组挡着，本来就连不上。
    ///    现在这条走 443（基本不会被 ISP 拦），回的是同一台机器。
    static let backupServer = "https://sucai.lingyan.cyou"

    @Published var server: String
    @Published var apiKey: String

    private let store = UserDefaults.standard
    private static let keyServer = "ly_server"
    private static let keyApiKey = "ly_apikey"

    private init() {
        let args = ProcessInfo.processInfo.arguments

        if let i = args.firstIndex(of: "-server"), i + 1 < args.count {
            server = args[i + 1]                       // 截图自检用
        } else {
            server = store.string(forKey: Self.keyServer) ?? Self.defaultServer
        }
        if let i = args.firstIndex(of: "-apiKey"), i + 1 < args.count {
            apiKey = args[i + 1]
        } else {
            apiKey = store.string(forKey: Self.keyApiKey) ?? ""
        }
        if AppConfig.isDemo {
            server = "demo"
            apiKey = "DEMO"
        }
        if args.contains("-showSetup") {
            // 截图自检要单独拍「首次打开」那一屏（跟 -demo 是一对开关）
            server = Self.defaultServer
            apiKey = ""
        }
    }

    /// 演示/截图模式：全部走本地假数据，一个网络请求都不发。
    static var isDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    /// 强制显示「首次打开」的设置页（截图用）
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
        return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 给界面看的短地址（去掉协议）
    var shortServer: String {
        var s = baseURL
        for p in ["https://", "http://"] where s.hasPrefix(p) {
            s.removeFirst(p.count)
        }
        return s
    }

    var keyHint: String {
        let k = apiKey
        if k.count <= 14 { return k }
        return String(k.prefix(10)) + "…" + String(k.suffix(4))
    }

    func save(server: String, key: String) {
        let s = AppConfig.normalize(server)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = s
        self.apiKey = k
        store.set(s, forKey: Self.keyServer)
        store.set(k, forKey: Self.keyApiKey)
    }

    func signOut() {
        apiKey = ""
        store.removeObject(forKey: Self.keyApiKey)
    }
}
