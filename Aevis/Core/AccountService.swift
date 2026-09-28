import CryptoKit
import Foundation

/// 账号 —— 给「以后要接的那个服务器」留的接口层。
///
/// 用户的原话：「我希望到时候点进去的话加一个注册账号，到时候会拿新的服务器跟你对接。」
///
/// 所以现在**只做界面和接口层，不做任何假设**：
/// 服务器地址是他自己填的、留空就是「未连接」；接口路径按最普通的 REST 写法，
/// 等他那边定下来，改这一处就够了（界面一行都不用动）。
///
/// 三条硬规矩：
/// 1. **离线可用**。没登录、连不上，App 的所有功能照常 —— 这是本地 App，
///    账号只是"多一样东西"，绝不能变成"必须先登录"。
/// 2. **密码不落盘**。登录成功后只存 token（进钥匙串），密码当场用完就丢。
/// 3. 失败要说清是哪一步（连不上 / 密码错 / 服务器返回了什么），不许吞成一句"失败了"。
final class AccountService: ObservableObject {

    static let shared = AccountService()

    /// 服务器地址变了、或者登录状态变了，界面要跟着刷新。
    @Published private(set) var profile: Profile?
    @Published private(set) var busy = false
    @Published var lastError: String?

    /// 服务器上的用户信息。
    ///
    /// ⚠️ 这个结构体**不落盘**（只有 token 进钥匙串），所以以后加字段是安全的 ——
    ///    不会出现"老版本存下来的 JSON 解不出来"那种事。
    struct Profile: Codable, Hashable {
        var id: String
        /// 邮箱。也是登录时「账号」那一栏可以填的东西之一。
        var username: String
        /// 昵称，用户自己设的。空 = 没设过。
        var nickname: String
        /// 账号号（8 位数字，像 QQ 号）。
        /// ⚠️ 服务端是**懒补发**：老账号第一次拉资料时才生成，所以可能是空串。
        var accountNo: String
        /// 头像地址，服务端给的是**路径**（`/api/avatar?name=xxx`）。
        /// 空 = 没设过头像，界面回落到昵称首字。
        var avatar: String
        var expiresAt: Date?

        /// 界面上显示哪个名字 —— 昵称优先，其次账号号，最后邮箱。
        var displayName: String {
            if !nickname.isEmpty { return nickname }
            if !accountNo.isEmpty { return accountNo }
            return username
        }

        /// 头像没设过时，界面用这个字当占位。
        var initial: String {
            let base = nickname.isEmpty ? (accountNo.isEmpty ? username : accountNo) : nickname
            return base.isEmpty ? "A" : String(base.prefix(1)).uppercased()
        }
    }

    private init() {}

    // MARK: - 状态

    private var settings: AppSettings { AppSettings.shared }

    var isConfigured: Bool {
        !settings.accountServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isSignedIn: Bool {
        !settings.accountToken.isEmpty
    }

    /// 「现在是什么状态」—— 界面直接显示这一句。
    var statusLine: String {
        if !isConfigured { return "还没填服务器地址。这个功能是可选的，不填也不影响别的。" }
        if isSignedIn {
            if let profile { return "已登录：" + profile.displayName }
            return "已登录（还没拉到资料）"
        }
        return "还没登录。可以用账号号 + 密码，或者用邮箱验证码登录。"
    }

    /// 头像的完整地址。没设过头像返回 nil（界面自己回落成首字）。
    ///
    /// ⚠️ 服务端在 `profile.avatar` 里给的是**路径**（`/api/avatar?name=..`），
    ///    这里补上**当前线路**的域名 —— 所以换线（线路一 ↔ 线路二）之后
    ///    头像也跟着走新线，不用重新登录。
    var avatarURL: URL? {
        guard let path = profile?.avatar, !path.isEmpty else { return nil }
        // 万一以后服务端改成给绝对地址，也能直接用
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        return URL(string: base + path)
    }

    private var base: String {
        var text = settings.accountServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - 注册 / 登录 / 退出

    // MARK: - 登录 / 退出
    //
    // ⚠️ **注册不在这里**：注册必须有**注册码**（一人一码，在群里找机器人领），
    //    服务端只有 `/api/register/start` + `/api/register/finish`。
    //    早先这里有个 `register()` 打的是 `/api/register` —— 那个接口**根本不存在**，
    //    点下去只会 404（2026-09-28 清理）。注册一律走网页登录页。

    /// 账号号 / 邮箱 + 密码 登录。
    ///
    /// 「账号」那一栏**两种都收**（服务端自己分辨是邮箱还是账号号）——
    /// 别让用户去想"我该填哪个"，老用户压根没有账号号。
    func signIn(account: String, password: String) async throws {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { throw AccountError.missingFields }
        let json = try await post("/api/login", ["account": name, "password": password])
        try adopt(json)
        // 登录接口只回 token（不回资料）→ 顺手拉一次，界面上就能立刻显示
        // 昵称 / 账号号 / 头像，不用用户再点一下「刷新资料」。
        await refreshProfile()
    }

    /// 退出只清本地的 token。**不调服务器** —— 退出不该因为连不上而失败。
    func signOut() {
        settings.accountToken = ""
        settings.accountExpiresAt = 0
        profile = nil
        lastError = nil
    }

    /// 有 token 的时候拉一次资料，顺便验证 token 还有效。
    @MainActor
    func refreshProfile() async {
        guard isConfigured, isSignedIn else { return }
        busy = true
        defer { busy = false }
        do {
            profile = Self.profile(from: try await get("/api/me"))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 网页登录（唯一的路）
    //
    // 账号后端是**邮箱验证码**（没有密码），所以 App 里不该有密码框。
    // 做法：打开官网登录页 → 用户收码登录（以后要注册就在同一页用注册码注册）
    //      → 页面跳 `aevis://login?token=...` → 我们把 token 收下。
    // 输验证码的是系统浏览器，**凭据不经过我们的代码**。

    /// 拿去给系统浏览器打开的登录页。
    func webLoginURL() -> URL? {
        URL(string: base + "/")
    }

    /// 收下登录页带回来的 token。拉一次资料确认它真的能用。
    @MainActor
    func adoptWebToken(_ raw: String) async throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw AccountError.badResponse("登录页没把凭证带回来。")
        }
        let previous = settings.accountToken
        settings.accountToken = token
        do {
            profile = Self.profile(from: try await get("/api/me"))
            lastError = nil
        } catch {
            // 拉不到就回滚 —— 别留一个"看起来登录了、其实用不了"的状态
            settings.accountToken = previous
            throw error
        }
    }

    /// 给别的模块用：带着账号 token 调服务器（百度网盘连接就用这个）。
    func authedGet(_ path: String) async throws -> [String: Any] {
        try await get(path)
    }

    func authedPost(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await post(path, body)
    }

    // MARK: - 底层

    private func adopt(_ json: [String: Any]) throws {
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw AccountError.badResponse(
                (json["error"] as? String) ?? "服务器没给 token（返回里有这些字段："
                    + json.keys.sorted().joined(separator: ",") + "）"
            )
        }
        settings.accountToken = token
        if let expires = json["expires_in"] as? Double {
            settings.accountExpiresAt = Date().timeIntervalSince1970 + expires
        } else if let stamp = json["expires_at"] as? Double {
            settings.accountExpiresAt = stamp
        }
        if let user = json["user"] as? [String: Any] {
            profile = Self.profile(from: user)
        }
        lastError = nil
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        var request = try request(path)
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func request(_ path: String) throws -> URLRequest {
        guard isConfigured else { throw AccountError.notConfigured }
        guard let url = URL(string: base + path) else { throw AccountError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if isSignedIn {
            request.setValue("Bearer \(settings.accountToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.unreachable(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        switch status {
        case 200..<300:
            guard let json else {
                throw AccountError.badResponse(String(decoding: data.prefix(160), as: UTF8.self))
            }
            return json
        case 401, 403:
            // token 失效就把本地那份清掉，免得界面一直显示"已登录"
            signOut()
            throw AccountError.unauthorized
        default:
            // 服务器自己说的话最有用，优先原样带出来
            let serverSaid = (json?["error"] as? String)
                ?? (json?["message"] as? String)
                ?? String(decoding: data.prefix(160), as: UTF8.self)
            throw AccountError.http(status: status, body: serverSaid)
        }
    }

    // MARK: - 零件

    private static func profile(from json: [String: Any]) -> Profile {
        // 服务器三种形状都认：
        //   `{"profile": {…}}` ← **我们后端 `/api/me` 就是这种**（2026-09-28 起：
        //                        资料在 `profile` 里，顶层的 email/created_at 是账号元信息）
        //   `{"user": {…}}`
        //   用户字段直接平铺在顶层
        //
        // ⚠️ 顺序不能反：`profile` 优先。顶层的 email 和 profile 里的 email 是同一个值，
        //    但 `account_no` / `nickname` / `avatar` **只在 profile 里** ——
        //    先取平铺的话，这几个字段永远是空的（界面上就是"昵称头像一直不显示"）。
        let user = (json["profile"] as? [String: Any])
            ?? (json["user"] as? [String: Any])
            ?? json
        let email = Self.text(user["email"])
        return Profile(
            id: Self.text(user["id"]).isEmpty ? email : Self.text(user["id"]),
            username: email.isEmpty ? ((user["username"] as? String) ?? "") : email,
            nickname: (user["nickname"] as? String) ?? "",
            accountNo: Self.text(user["account_no"]),
            avatar: Self.text(user["avatar"]),
            expiresAt: nil
        )
    }

    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        if let number = value as? Int64 { return String(number) }
        return ""
    }

    /// 设备标识：装到哪台机器上是稳定的，但**不含任何硬件唯一码** ——
    /// 只是给服务器做区分用的一个随机串，第一次生成后存在本机。
    static func deviceTag() -> String {
        let key = "aevis.account.deviceTag"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let seed = UUID().uuidString + "-" + String(Date().timeIntervalSince1970)
        let digest = SHA256.hash(data: Data(seed.utf8))
        let tag = digest.map { String(format: "%02x", $0) }.joined().prefix(24)
        UserDefaults.standard.set(String(tag), forKey: key)
        return String(tag)
    }
}

enum AccountError: LocalizedError {
    case notConfigured
    case badURL
    case missingFields
    case unreachable(String)
    case unauthorized
    case http(status: Int, body: String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填服务器地址。"
        case .badURL:
            return "服务器地址拼不出合法网址，检查一下是不是写全了（要带 http:// 或 https://）。"
        case .missingFields:
            return "账号和密码都要填。"
        case let .unreachable(reason):
            return "连不上服务器：\(reason)"
        case .unauthorized:
            return "登录已经失效了，重新登录一次。"
        case let .http(status, body):
            return "服务器返回 \(status)：\(body.prefix(120))"
        case let .badResponse(text):
            return "服务器返回的内容看不懂：\(text.prefix(120))"
        }
    }
}
