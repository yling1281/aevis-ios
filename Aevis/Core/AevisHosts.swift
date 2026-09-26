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
    static let siteDomain = "sucai.apekin.com"

    /// 账号站：登录、激活、注册码、管理后台。和静态站同一台服务器、同一套后端。
    static let accountDomain = "account.apekin.com"

    // MARK: - 拼 URL

    static let siteBase = "https://" + siteDomain
    static let accountBase = "https://" + accountDomain

    /// `AevisHosts.site("/rules.html")`
    static func site(_ path: String) -> String { siteBase + path }
    static func account(_ path: String) -> String { accountBase + path }
    static func siteURL(_ path: String) -> URL? { URL(string: siteBase + path) }
    static func accountURL(_ path: String) -> URL? { URL(string: accountBase + path) }

    // MARK: - 老域名 / 备用域名

    /// 老域名。⚠️ **不是废弃值，是"备用域名"**：
    /// 阿里云的备案拦截是按**线路抽样**触发的 —— 同一条链接，有的用户能开、有的开到拦截页。
    /// 所以两个域名互为备用，谁通走谁（见 `AccountEndpoint.refresh()`）。
    static let legacySiteDomain = "lingyan.cyou"
    static let legacyAccountDomain = "account.lingyan.cyou"

    // MARK: - 服务器线路（线路一 / 线路二）

    /// 一条线路。用结构体而不是元组 —— 元组不能给 `ForEach` 当 id（KeyPath 取不到元组元素），
    /// 界面上要遍历两条线，所以这里必须是能 `Identifiable` 的类型。
    struct Line: Identifiable, Hashable {
        let name: String
        let base: String
        var id: String { name }
    }

    /// 两条线路，**顺序就是优先级**。用户口径：「线路一、线路二」——
    /// 主 App 和管理端**共用这一份**，别再各写一遍。
    ///
    /// 线路一 = 新备案域名（主用）；线路二 = 老域名（备用）。
    /// App 启动时依次探一下，谁通走谁（`AccountEndpoint.refresh()`）。
    static let accountLines: [Line] = [
        Line(name: "线路一", base: "https://" + accountDomain),
        Line(name: "线路二", base: "https://" + legacyAccountDomain),
    ]

    static var accountCandidates: [String] { accountLines.map { $0.base } }

    /// 地址 → 线路名（界面上显示"现在走的是哪条"用）。
    static func lineName(for base: String) -> String? {
        accountLines.first { $0.base == base }?.name
    }
}
