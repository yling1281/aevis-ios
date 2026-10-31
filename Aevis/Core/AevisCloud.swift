import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 姜言自建后端（`ai.aevis.cn` / `aevis.cn`）的接入层。
///
/// ## 为什么单独一个文件，不塞进 `AccountService`
/// `AccountService` 连的是**账号站**（`account.aevis.cn`，登录 / 激活 / 注册码），
/// 那是「这台设备是谁的」。这里连的是**业务站**（`aevis.cn`，聊天记录 / 订单 / 备份码），
/// 那是「这个账号里有什么、花了多少、能搬到哪去」。
///
/// 两套域名、两套令牌、两种失败含义 —— 混在一个文件里，半年后没人敢动。
///
/// ## 三件事
/// 1. **内置 API**：`chatBase` 指向兼容层，登录后自动填进 `AppSettings.baseURL`，
///    用户不用自己抄地址（`ProviderPreset.aevis` 就是为此存在的）。
/// 2. **充值**：下单在 App 里发起，收银台跳网页 —— 微信/支付宝的付款确认页
///    **必须**在系统浏览器里过一遍，WKWebView 拿不到回调。这不是偷懒，是平台限制。
/// 3. **转移账号**：生成/认领备份码，见 `BackupCodeService`。
enum AevisCloud {

    // MARK: - 地址

    /// 业务站根。账号站是另一个域名，别混。
    /// 业务站根地址。
    ///
    /// 🔴 2026-10-31：加上 4-4 的 nginx 前缀。原来这里是 `https://aevis.cn`，
    ///    拼出来的是 `https://aevis.cn/v1/xxx` —— 那条路径在线上**根本没有反代**，
    ///    会被 nginx 兜成官网首页 HTML（状态 200，内容是网页），解析必然失败。
    ///    真正的接口根是 `https://aevis.cn/prod-api/aevis`（= `AevisHosts.accountBase`）。
    static let webBase = AevisHosts.accountBase

    /// **模型兼容层**（OpenAI 协议）。`/v1/models`、`/v1/chat/completions` 都在这儿。
    ///
    /// ⚠️ 必须带 `/v1` 尾巴 —— `LLMService` 拼的是 `baseURL + "/chat/completions"`，
    ///    少写一段会变成 `/chat/completions` 打在根上，404。
    static let chatBase = "https://ai.aevis.cn/v1"

    /// 网页版充值页。`App` 跳过去，用户用已登录的账号付款。
    static let walletURL = webBase + "/#/wallet"

    /// 网页版「我的 API 密钥」页 —— App 里「内置 API」那行的说明就指向这儿。
    static let apiKeyURL = webBase + "/#/me"

    // MARK: - 统一请求

    enum CloudError: LocalizedError {
        case notSignedIn
        case badURL
        case http(Int, String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "还没登录姜言账号，先登录再操作。"
            case .badURL:
                return "接口地址不对。"
            case let .http(code, body):
                if code == 401 || code == 403 { return "登录状态过期了，重新登录一下。" }
                return "服务器返回 \(code)：\(body.prefix(120))"
            case let .server(msg):
                return msg
            }
        }
    }

    /// 登录后拿到的业务站令牌。**只进钥匙串**，跟账号站的 token 分开存。
    static let tokenKey = "aevis.cloud.token"

    static var token: String {
        get {
            // 🔴 2026-10-31：账号体系统一到 4-4 之后，**账号站和业务站是同一个后端、
            //    同一个令牌**（`auth_session` 那一套）。原来这里存的 `aevis.cloud.token`
            //    来自 `/v1/auth/login` —— 那个路径在 4-4 上不存在，方法本身也是零调用点的死代码。
            //    继续留两套令牌的后果很具体：账号明明登着，`/v1/points`、`/v1/wallet`
            //    全部 401，界面表现为"一直转圈/一直让我登录"。
            //    所以优先用账号令牌；钥匙串里那份只作为**极老版本**的兜底。
            let account = AppSettings.shared.accountToken
            if !account.isEmpty { return account }
            return Keychain.get(tokenKey) ?? ""
        }
        set { Keychain.set(newValue, for: tokenKey) }
    }

    static var isSignedIn: Bool { !token.isEmpty }

    /// 发请求。`path` 写 `/v1/xxx`（相对 `webBase`）。
    static func call(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        timeout: TimeInterval = 20
    ) async throws -> [String: Any] {
        guard let url = URL(string: webBase + path) else { throw CloudError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badURL }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // 后端统一 `{"code":200,"data":{…},"msg":"…"}`；`code != 200` 就是业务失败。
        let code = (json["code"] as? Int) ?? http.statusCode
        guard (200..<300).contains(code) else {
            let msg = (json["msg"] as? String) ?? "未知错误"
            if code == 401 || code == 403 { throw CloudError.notSignedIn }
            throw CloudError.http(code, msg)
        }
        // 有的接口 data 是字典，有的直接平铺在顶层（`/v1/models` 就是 `{"object":…,"data":[…]}`）
        return (json["data"] as? [String: Any]) ?? json
    }

    // MARK: - 账号

    /// 登录后调一次：拿业务站令牌 + 把模型地址自动填好。
    ///
    /// ⚠️ **不要**把这一步塞进 `AccountService.refresh()` —— 那是账号站的网络请求，
    ///    在那条链路上加业务站的调用，会让「服务器地址都探不通」的降级判断失真。
    ///
    /// ⚠️ 标了 `@MainActor`：末尾要写 `AppSettings.baseURL`（`@Published`，
    ///    会触发界面刷新 + `syncIntoActiveProfile` 回写），在后台线程写会让
    ///    SwiftUI 状态更新落到非主线程。令牌本身不挑线程，但为一致性整段放主线程。
    @MainActor
    static func signIn(email: String, password: String) async throws -> [String: Any] {
        guard let url = URL(string: webBase + "/v1/auth/login") else { throw CloudError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["account": email, "password": password]
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.badURL }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (json["code"] as? Int) ?? http.statusCode
        guard (200..<300).contains(code) else {
            throw CloudError.server((json["msg"] as? String) ?? "登录失败（\(code)）")
        }
        let payload = (json["data"] as? [String: Any]) ?? json
        // 后端 `v1_issue` 返回的就是 `{"token": "...", "user": {…}}`
        guard let t = (payload["token"] as? String) ?? (json["token"] as? String), !t.isEmpty else {
            throw CloudError.server("服务器没返回令牌")
        }
        token = t

        // ⚠️ 顺手把内置 API 填进去 —— 用户明确要「API 提前加好」，不许让他手填地址。
        //    用 chatBase 而不是 /v1 以外的任何东西：兼容层就认这个前缀。
        let settings = AppSettings.shared
        settings.baseURL = chatBase
        // ⚠️ `isEmpty` 是 `String` 的成员，**不是 `NSString` 的**。
        //    写成 `(x as NSString).isEmpty` 编译不过（'NSString' has no member 'isEmpty'）。
        if settings.model.isEmpty || settings.model == "gpt-4o-mini" {
            settings.model = "aevis-chat"
        }
        return payload
    }

    static func signOut() {
        token = ""
    }

    /// 余额 / 到期日。界面顶部那一行就靠它。
    ///
    /// ⚠️ 后端 `/v1/wallet` **不返回 `plan`**（套餐名在 `/v1/me` 里），
    ///    所以这里只解能解到的，别编一个字段名上去 —— 编了就是永远为空。
    struct Wallet {
        var balance: Double
        var recharge: Double
        var cost: Double
        var monthCost: Double
        var expireAt: String
        var payEnabled: Bool
    }

    static func wallet() async throws -> Wallet {
        let json = try await call("/v1/wallet")
        return Wallet(
            balance: (json["balance"] as? Double) ?? 0,
            recharge: (json["recharge"] as? Double) ?? 0,
            cost: (json["cost"] as? Double) ?? 0,
            monthCost: (json["monthCost"] as? Double) ?? 0,
            expireAt: (json["expireAt"] as? String) ?? "",
            payEnabled: (json["payEnabled"] as? Bool) ?? false
        )
    }

    // MARK: - 充值

    struct Product: Identifiable {
        var pid: Int
        var name: String
        var amount: Double
        var bonus: Double
        /// `credit` = 充余额；`plan` = 买套餐（改 `tenant.plan` 并顺延到期日）。
        var kind: String
        var days: Int
        var badge: String
        var planCode: String

        var id: Int { pid }

        /// 套餐显示「30 天有效期」，余额包显示「充到余额」。
        var detail: String {
            kind == "plan" ? "\(days) 天有效期" : (bonus > 0 ? "充 \(bonus) 元到余额" : "充到余额")
        }

        var isPlan: Bool { kind == "plan" }
    }

    /// 套餐列表。
    ///
    /// ⚠️ `/v1/products` 返回的是**裸数组**（`ok(out)` 里 `out` 就是 list），
    ///    所以走 `call()` 拿不到 —— 得单独按数组解。
    ///    对比：`/v1/wallet` 里的 `products` **没有 `kind` / `planCode`**
    ///    （后端那里手写了一份精简版）—— 所以**套餐一律以 `/v1/products` 为准**，
    ///    别图省事去读 wallet.products，那会让所有卡片都退化成余额包。
    static func products() async throws -> [Product] {
        guard let url = URL(string: webBase + "/v1/products") else { throw CloudError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.server("套餐列表解不出来")
        }
        guard (200..<300).contains(((root["code"] as? Int) ?? 200)) else {
            throw CloudError.server((root["msg"] as? String) ?? "取套餐失败")
        }
        let rows = (root["data"] as? [[String: Any]]) ?? []
        return rows.compactMap { row in
            guard let pid = (row["pid"] as? Int) else { return nil }
            return Product(
                pid: pid,
                name: (row["name"] as? String) ?? "套餐",
                amount: (row["amount"] as? Double) ?? 0,
                bonus: (row["bonus"] as? Double) ?? 0,
                kind: (row["kind"] as? String) ?? "credit",
                days: (row["days"] as? Int) ?? 30,
                badge: (row["badge"] as? String) ?? "",
                planCode: (row["planCode"] as? String) ?? ""
            )
        }
    }

    /// 下单。返回的 `payUrl` / `qrUrl` 要**在系统浏览器**打开。
    ///
    /// ⚠️ **不要**给这个结构体加 `Decodable`：字段都是手工从字典里取的
    ///    （后端金额给的是字符串，有的版本给数字），一旦让编译器自动解码，
    ///    哪天金额类型一变就是运行时崩溃 —— 手工取 + 兜底 0 才稳。
    struct Order {
        var orderNo: String
        var amount: String
        var payUrl: String
        var qrUrl: String
        var mock: Bool
        var msg: String
    }

    static func createOrder(pid: Int, payType: String = "wechat") async throws -> Order {
        let json = try await call("/v1/orders", method: "POST", body: ["pid": pid, "payType": payType])
        return Order(
            orderNo: (json["orderNo"] as? String) ?? "",
            amount: (json["amount"] as? String) ?? "",
            payUrl: (json["payUrl"] as? String) ?? "",
            qrUrl: (json["qrUrl"] as? String) ?? "",
            mock: (json["mock"] as? Bool) ?? false,
            msg: (json["msg"] as? String) ?? ""
        )
    }

    /// 轮询订单状态。`1` = 已支付。App 回到前台时也调一次。
    static func orderPaid(_ no: String) async throws -> Bool {
        guard !no.isEmpty else { return false }
        let json = try await call("/v1/orders/\(no)")
        return ((json["status"] as? String) ?? "0") == "1"
    }

    /// 打开收银台。
    ///
    /// ⚠️ **必须用 `UIApplication.shared.open`**（系统浏览器），
    ///    不能用 `WKWebView`：微信/支付宝的付款确认要调起系统组件，
    ///    内嵌浏览器里回调拿不到，用户会看到「付了钱没到账」。
    @MainActor
    static func openCashier(_ url: String) {
        guard let u = URL(string: url), !url.isEmpty else { return }
        UIApplication.shared.open(u)
    }
}

/// 备份码 —— 转移账号。
///
/// ## 流程
/// - 老设备：`create()`，把本地数据打包换成一个 `ABCD-1234` 的码
/// - 新设备：`claim()`，登录后输入这个码，日记 / 记忆 / 周期记录整体搬过来
///
/// ## 三个不能省的约束
/// 1. **一个码只能被认领一次**（后端 `status` 从 `pending` 变 `claimed`）。
/// 2. **30 天过期**（后端 `_BK_DAYS`）。
/// 3. **单包 2MB 上限**（后端 `3 * 1024 * 1024` 压缩后）。超了要让用户先精简日记，
///    别默默截断 —— 截断了用户以为搬完了，其实在丢东西。
enum BackupCodeService {

    struct Created {
        var code: String
        var expireAt: String
        var size: Int
        var claimed: Bool
    }

    struct Info {
        var code: String
        var claimed: Bool
        var status: String
        var expireAt: String
        var size: Int
        var expired: Bool
        var source: String
    }

    /// 生成备份码。`payload` 是要带走的数据（键值随便，后端原样存）。
    ///
    /// - Note: 不传也能生成（后端允许匿名），但那样生成的码是 `pending` 状态，
    ///   任何账号都能认领 —— **等于把你的日记公开了**。所以界面上必须先登录。
    static func create(payload: [String: Any], source: String = "ios") async throws -> Created {
        let json = try await AevisCloud.call(
            "/v1/backup/code", method: "POST",
            body: ["payload": payload, "source": source]
        )
        return Created(
            code: (json["code"] as? String) ?? "",
            expireAt: (json["expireAt"] as? String) ?? "",
            size: (json["size"] as? Int) ?? 0,
            claimed: (json["claimed"] as? Bool) ?? false
        )
    }

    /// 查码状态（不返回内容）。界面上让用户输完码先「检查一下」。
    static func info(_ code: String) async throws -> Info {
        let json = try await AevisCloud.call("/v1/backup/info?code=\(escaped(code))")
        return Info(
            code: (json["code"] as? String) ?? code,
            claimed: (json["claimed"] as? Bool) ?? false,
            status: (json["status"] as? String) ?? "",
            expireAt: (json["expireAt"] as? String) ?? "",
            size: (json["size"] as? Int) ?? 0,
            expired: (json["expired"] as? Bool) ?? false,
            source: (json["source"] as? String) ?? ""
        )
    }

    /// 认领（搬家）。必须先登录 —— 后端 `v1_u()` 拿不到就 401。
    @discardableResult
    static func claim(_ code: String) async throws -> [String: Int] {
        let json = try await AevisCloud.call("/v1/backup/claim", method: "POST", body: ["code": code])
        let stats = (json["stats"] as? [String: Any]) ?? [:]
        var out: [String: Int] = [:]
        for (k, v) in stats {
            if let n = v as? Int { out[k] = n }
        }
        return out
    }

    /// 云端 → iOS 整包拉走（登录同一账号即可，不限码）。
    static func pull() async throws -> [String: Any] {
        try await AevisCloud.call("/v1/backup/pull")
    }

    /// 备份码允许 `-`，用户很可能直接从聊天记录里复制过来，会带空格和连字符混着。
    /// 后端 `_bk_norm` 也会洗一遍，这里先洗是为了让「查一下」这一步就能给出准确反馈。
    static func normalize(_ raw: String) -> String {
        raw.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "–", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func escaped(_ code: String) -> String {
        normalize(code).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}