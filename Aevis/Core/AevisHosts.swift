import Foundation

/// 站点 / 后端的域名 —— **全项目只此一份**，别的地方一律别写字面量。
///
/// 为什么要有这个文件：域名本来是散在各处的字符串，`lingyan.cyou` 被阿里云按
/// **备案状态**在 80 端口整站拦掉（`Server: Beaver` + `Non-compliance ICP Filing`），
/// 要换域名时发现 **6 处**都写死了 `account.lingyan.cyou`，还有免责声明、规则页、
/// 更新源各写了一遍 —— 漏一处就是一个用户报"登不进去"。
///
/// 换域名的正确做法（2026-09-26 定）：
///   1. 服务器（`server/nginx-aevis-apekin.conf`）+ 证书先在 `apekin.com` 上线并验证
///   2. **然后**改下面这两个值
///   3. 出包 —— 改完必须出新包，用户装的那份自己不会变
///
/// ⚠️ 这两个值改完，**旧包（≤0.0.70）里还是旧域名**，会一直连不上。
///    所以顺序不能反：先把新域名跑通，再发包。
enum AevisHosts {

    // MARK: - 对外域名

    /// 静态站：安装页 / IPA / `source.json` / 规则 / 免责声明。
    static let siteDomain = "sucai.aevis.cn"

    /// 账号站：登录、激活、注册码、管理后台。和静态站同一台服务器、同一套后端。
    static let accountDomain = "account.aevis.cn"

    // MARK: - 接口的随机入口（2026-10-02）

    /// App 调 `/api/...` 走的那段**随机前缀**。
    ///
    /// 老板原话：「APP 接口的话，你是不是也要改啊」「**不要拿那些就是很大众的东西**」
    /// ⇒ 接口不再挂在裸 `/api/` 上，而是挂在 `/<这段随机串>/api/` 上。
    /// 36 进制 8 位（约 2.8 万亿种），猜不出来。
    ///
    /// ⚠️ **改这个值要两处一起改**：
    ///   ① 这里
    ///   ② 服务器 `server/nginx-aevis-apekin.conf` 里那两处
    ///      `location = /<前缀>` 和 `location ^~ /<前缀>/api/`
    /// 想**不出新包**就切，别改这里 —— 去后台的「远端配置」写
    /// `accountBase = https://account.aevis.cn/<新前缀>`（见 `remoteOverrideKey`）。
    ///
    /// ⚠️ **老路径 `/api/...` 必须继续活着**（老板要求「做过渡」）：
    ///    手机上装的老包（≤0.0.95）、QQ / 百度的回调、支付宝 / PayPro 的回调
    ///    都还指着它。等大家都换了新包再单独收掉。
    static let apiPath = "/k5stbt2o"

    /// 远端配置里那个能**覆盖接口地址**的键（存在后端的 `app_config` 表里）。
    /// 改它的值 = 所有装了新包的 App 下次启动 / 回前台就切过去，**不用重新出包**。
    /// 这就是「不更新包直接切换」。
    static let remoteOverrideKey = "accountBase"

    /// 后台页在服务器上那条**随机路径** —— 必须和后端 `server/account/app.py`
    /// 里的 `ADMIN_PATH` 一字不差（改要两处一起改）。
    static let adminPath = "/afwjs9e870"

    // MARK: - 拼 URL
    //
    // ⚠️ 三个 base 别用混：
    //   · `siteBase`        静态站（谁都能看：安装页、源、规则、免责声明）
    //   · `accountBase`     **接口**根，带随机前缀 —— 所有 `/api/...` 走它
    //   · `accountWebBase`  **人看的网页**根，不带前缀（登录页 / `/me` / 后台页）
    //     ↑ 这三个混用就会 404：带前缀的 `/me` 服务器上根本不存在。

    static let siteBase = "https://" + siteDomain
    static let accountBase = "https://" + accountDomain + apiPath

    /// 同一个域名，**不带前缀** —— 过渡期兜底（老路径还在）。
    static let accountPlainBase = "https://" + accountDomain
    static let accountWebBase = accountPlainBase

    /// `AevisHosts.site("/rules")`
    static func site(_ path: String) -> String { siteBase + path }
    /// **接口**地址：`AevisHosts.account("/api/me")`
    static func account(_ path: String) -> String { accountBase + path }
    static func accountURL(_ path: String) -> URL? { URL(string: accountBase + path) }
    /// **网页**地址：`AevisHosts.accountWeb("/me")`
    static func accountWeb(_ path: String) -> String { accountWebBase + path }
    static func accountWebURL(_ path: String) -> URL? { URL(string: accountWebBase + path) }
    static func siteURL(_ path: String) -> URL? { URL(string: siteBase + path) }

    // MARK: - 备用域名（线路二 / 线路三）

    /// 最老的备用域名（线路三）。⚠️ **不是废弃值，是"备用域名"**：
    /// 阿里云的备案拦截是按**线路抽样**触发的 —— 同一条链接，有的用户能开、有的开到拦截页。
    /// 所以三个域名互为备用，谁通走谁（见 `AccountEndpoint.refresh()`）。
    static let legacySiteDomain = "lingyan.cyou"
    static let legacyAccountDomain = "account.lingyan.cyou"
    static let legacyAccountBase = "https://" + legacyAccountDomain

    /// 上一代主域名（现役 → 转备用，线路二）。
    ///
    /// ⚠️ 这一条**必须带 `apiPath` 前缀** —— apekin 那台 nginx 块里配了
    ///    `location ^~ /k5stbt2o/api/`，不带前缀的裸 `/api/` 在那台上是 404。
    static let apekinSiteDomain = "sucai.apekin.com"
    static let apekinAccountDomain = "account.apekin.com"
    static let apekinAccountBase = "https://" + apekinAccountDomain + apiPath

    // MARK: - 服务器线路（线路一 / 线路二 / 线路三）

    /// 一条线路。用结构体而不是元组 —— 元组不能给 `ForEach` 当 id（KeyPath 取不到元组元素），
    /// 界面上要遍历三条线，所以这里必须是能 `Identifiable` 的类型。
    struct Line: Identifiable, Hashable {
        let name: String
        let base: String
        var id: String { name }
    }

    /// 三条线路，**顺序就是优先级**。用户口径：「三个路线你自己点选」——
    /// 主 App 和管理端**共用这一份**，别再各写一遍。
    ///
    /// 线路一 = `aevis.cn`（新主站，主用）+ **接口随机前缀**；
    /// 线路二 = `apekin.com`（上一代，现役 → 转备用）+ **接口随机前缀**；
    /// 线路三 = `lingyan.cyou`（最老）**裸 `/api/`，故意不加前缀**。
    /// App 启动时依次探一下，谁通走谁（`AccountEndpoint.refresh()`）；
    /// 用户也能在设置里手动点选（`AccountEndpoint.use(_:)`）。
    /// ⚠️ 线路一 / 线路二**都带前缀**（两台都配了 `location ^~ /k5stbt2o/api/`）；
    ///    线路三**故意不带** —— 老域名那台上没配那条前缀规则，
    ///    加了就是 404；它走的是原来那条裸 `/api/`。
    static let accountLines: [Line] = [
        Line(name: "线路一", base: accountBase),         // aevis.cn（新主站）+ 接口随机前缀
        Line(name: "线路二", base: apekinAccountBase),    // apekin.com（上一代）+ 接口随机前缀
        Line(name: "线路三", base: legacyAccountBase),    // lingyan.cyou（最老，裸 /api/，不带前缀）
    ]

    static var accountCandidates: [String] { accountLines.map { $0.base } }

    /// 地址 → 线路名（界面上显示"现在走的是哪条"用）。
    static func lineName(for base: String) -> String? {
        accountLines.first { $0.base == base }?.name
    }

    // MARK: - 配对 / 信令（生态第一期，2026-10-02）

    /// 配对服务跑在**腾讯云**那台（不是阿里云这两台）—— 老板定的「私服走腾讯云」。
    ///
    /// ⚠️ **这台没有域名**，所以就是 IP + 端口。**这不是缺陷，是设计**：
    ///   · 二维码里放的是我们自己的 `aevis://pair?...` 串 —— App 自己解析，
    ///     不需要浏览器能打开，所以不需要域名也不需要证书；
    ///   · 明文 HTTP 已经在 `Info.plist` 里放开（`NSAllowsArbitraryLoads`，`:94`）。
    /// ⚠️ 但**别把它写成 `https://`** —— 那台上没有证书、也没装 nginx，
    ///    改成 https 会连不上，而且错误信息会很难懂。
    static let pairHost = "106.52.113.18"
    static let pairPort = 9100

    /// 客户端标识。
    ///
    /// **它不是密钥** —— 编进包里谁都能扒出来。它只用来挡掉「随手扫到一个 IP 就乱戳的人」，
    /// 让扫描器收不到正经响应。真正的门是 `ticket` ＋ 用户点的那一下「同意」。
    /// 所以它放在这儿（源码里）而不是 `BuiltInSecrets` —— 那个文件是给**真机密**用的。
    static let pairClientToken = "aevis-pair-client-2026"

    /// 配对服务器根地址（编译进去的**锚点**）。
    static var pairBase: String { "http://\(pairHost):\(pairPort)" }

    /// 远端配置里能**覆盖配对服务器地址**的键。
    /// 想换服务器又不想重出包，就在后台把它的值写成 `http://新地址:端口`
    /// （走的是 `app_config` 那套，跟 `accountBase` 一个机制）。
    static let pairRemoteOverrideKey = "pairBase"
}
