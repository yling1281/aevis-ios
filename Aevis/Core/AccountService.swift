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
    struct Profile: Codable, Hashable {
        var id: String
        var username: String
        var nickname: String
        var expiresAt: Date?
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
            if let profile { return "已登录：\(profile.nickname.isEmpty ? profile.username : profile.nickname)" }
            return "已登录（还没拉到资料）"
        }
        return "还没登录。可以注册一个，或者用已有的账号登录。"
    }

    private var base: String {
        var text = settings.accountServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: - 注册 / 登录 / 退出

    func register(username: String, password: String, nickname: String) async throws {
        let body: [String: Any] = [
            "username": username,
            "password": password,
            "nickname": nickname.isEmpty ? username : nickname,
            // 让服务器那边能区分设备 —— 用户很在意"一机一码"这类东西
            "device": Self.deviceTag()
        ]
        let json = try await post("/api/register", body)
        try adopt(json)
    }

    func signIn(username: String, password: String) async throws {
        let json = try await post("/api/login", ["username": username, "password": password])
        try adopt(json)
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
        // 服务器两种形状都认：`{"user": {...}}` 和把用户字段直接平铺在顶层。
        // 我们自己的后端是**平铺**那种（`/api/me` 直接回 email / created_at / login_count）。
        let user = (json["user"] as? [String: Any]) ?? json
        let email = Self.text(user["email"])
        return Profile(
            id: Self.text(user["id"]).isEmpty ? email : Self.text(user["id"]),
            username: email.isEmpty ? ((user["username"] as? String) ?? "") : email,
            nickname: (user["nickname"] as? String) ?? "",
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
