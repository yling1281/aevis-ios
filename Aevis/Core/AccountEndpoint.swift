import Foundation

/// 账号后端有**主域名 + 备用域名**两个，这里负责挑一个能通的。
///
/// 为什么非要有它：域名的拦截不是"全通或全断"，而是**按线路抽样**的 ——
/// `lingyan.cyou` 被阿里云按备案状态拦着，可有的线路照样能访问、有的只能看到拦截页；
/// 而 `sucai/account.apekin.com` 是已备案的新域名。
/// 写死任何一个都等于赌运气，所以开机探一次，谁通走谁，结果写进 `AppSettings.accountServerURL`。
///
/// 还有一层：**远端配置可以指定接口地址**（`AevisHosts.remoteOverrideKey`）——
/// 改后端一行配置就能换接口入口，不用重新发版。见 `refresh()` 第 ① 步。
///
/// ⚠️ 探活用的是真接口 `/api/health`，判定"状态码 < 400"——
///    为什么不是"任何 HTTP 应答都算通"，见 `reachable` 那段注释（栽过）。
enum AccountEndpoint {

    private static let key = "aevis.account.resolvedBase"

    /// 上一次探测到的可用地址（跟机器走，不跨设备）。
    static var resolved: String? { UserDefaults.standard.string(forKey: key) }

    /// 现在走的是哪条线路（"线路一" / "线路二"）。没探过就是 nil。
    static var activeLineName: String? {
        // 远端覆盖优先 —— 否则界面上会显示成"线路一"，而接口其实打在别处。
        if let remote = remoteOverride() { return AevisHosts.lineName(for: remote) }
        guard let base = resolved, !base.isEmpty else { return nil }
        return AevisHosts.lineName(for: base)
    }

    /// 依次探测候选线路，返回第一个能通的，并记下来。
    /// 全都不通就返回线路一 —— 让上层照常报错，而不是在这里假装成功。
    @discardableResult
    static func refresh() async -> String {
        // 🔴 ① 远端配置说走哪儿就走哪儿 —— 这是「**不发新包也能换接口入口**」那条路。
        //    老板原话：「我想要那种不更新包直接切换」。
        //    做法：在后端 `app_config` 表里写 `accountBase = https://<域名>/<新前缀>`
        //    （后台页的「远端配置」那一节就能改），所有装了新包的 App
        //    下次启动就切过去，**不用重新编译发版**。
        // ⚠️ 仍然要**探得通才用** —— 远端值写错了（或那条前缀规则被人改坏）
        //    不能把 App 一把带沟里：探不通就往下走。
        if let remote = remoteOverride(), await reachable(remote) {
            // ⚠️ **故意不写进 `resolved`**：那个缓存是"上次探到的那条线"，
            //    远端覆盖是**另一层**。写进去的话，把远端配置删掉也回不去了
            //    （第 ② 步会拿这份缓存接着用）—— 那就成了"改得回去吗"的坑。
            return remote
        }
        // ② 上次那条还通就继续用（省一次请求）
        if let cached = resolved, !cached.isEmpty, await reachable(cached) {
            return cached
        }
        // ③ 依次探候选
        for base in AevisHosts.accountCandidates where await reachable(base) {
            UserDefaults.standard.set(base, forKey: key)
            return base
        }
        return AevisHosts.accountBase
    }

    /// 远端配置里那个接口地址（没配就返回 nil）。顺手把末尾的 `/` 削掉 ——
    /// 拼接用的是 `base + "/api/..."`，多一个斜杠就是 `//api/...`。
    static func remoteOverride() -> String? {
        var text = RemoteConfig.shared.string(AevisHosts.remoteOverrideKey)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// 手动指定一条线路（用户在图里点"线路二"那种），存下来并返回能不能通。
    @discardableResult
    static func use(_ base: String) async -> Bool {
        guard await reachable(base) else { return false }
        UserDefaults.standard.set(base, forKey: key)
        return true
    }

    /// 这条线路**是不是真的能用**。
    ///
    /// ⚠️ 探的是 **`/api/health`（真接口）**，不是 `/` —— 这个改口径是 2026-10-02 被
    ///    随机前缀坑过之后改的：
    ///    原来探的是 `base + "/"`、而且"能收到 HTTP 响应就算通"。
    ///    可加了接口前缀之后，**前缀那条 nginx 规则一挂，`/` 照样有人应答（静态 404）**
    ///    ⇒ 被误判成"线路可用" ⇒ 然后所有 `/api/*` 全是 404，
    ///    用户看到的是"登录失败"，而不是"自动切到备用线"。
    ///    `/api/health` 是真接口，404 就是 404，能真正把两种情况分开。
    ///
    /// ⚠️ 判定仍然是"**状态码小于 400**"：不要求特定 JSON 内容，服务器一改返回体
    ///    这里不会误判；而 401/403 说明域名、TLS、服务器全活着 —— 但那不是我们
    ///    想知道的全部（前缀错了也是 4xx 起头），所以不再放行 401/403。
    ///
    /// **非 private** —— 管理端要复用同一套判断口径，两个 App 不能各判各的。
    static func reachable(_ base: String) async -> Bool {
        guard let url = URL(string: base + "/api/health") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode < 400
        } catch {
            return false
        }
    }
}
