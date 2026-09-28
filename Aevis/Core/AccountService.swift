import CryptoKit
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 账号 —— 给「以后要接的那个服务器」留的接口层。
///
/// 用户的原话：「我希望到时候点进去的话加一个注册账号，到时候会拿新的服务器跟你对接。」
///
/// 所以现在**只做界面和接口层，不做任何假设**：
/// 服务器地址是他自己填的、留空就是「未连接」；接口路径按最普通的 REST 写法，
/// 等他那边定下来，改这一处就够了（界面一行都不用动）。
///
/// 三条硬规矩：
/// 1. **登录过就能离线用**。用户 2026-09-28 拍板要**强制登录**（「你一定要强制性登录的，
///    去退出登录的话，就回到初始界面，就要登录账号」）—— 所以没登录进不了主界面。
///    但**登录过之后**（本地有 token）断网照进：聊天记录都在这台手机里，
///    拿网络去锁它等于把用户自己的东西扣住了。§只在"从没登录过"时才拦。
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
        await afterSignIn()
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
        // 验过了才做收尾（拉本地资料 + 绑设备）
        await applyToLocalProfile()
        await bindThisDevice()
    }

    /// 给别的模块用：带着账号 token 调服务器（百度网盘连接就用这个）。
    func authedGet(_ path: String) async throws -> [String: Any] {
        try await get(path)
    }

    func authedPost(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await post(path, body)
    }

    // MARK: - 原生登录（2026-09-28）
    //
    // 用户原话：「登录账号，你不要跳转网页了吧」「邮箱验证码那些也是内置啊」——
    // 所以验证码和密码**都在 App 自己的界面里**做完，不再开系统浏览器那一套。
    // （QQ 是唯一的例外：它必须在浏览器环境里跳授权，所以走**内置**浏览器。）

    /// 给已有账号发一封登录验证码。
    ///
    /// ⚠️ 服务端**只给库里有的邮箱发码**（没注册的会回 `not_registered`）——
    ///    这道门槛是防止有人拿它当发信机轰炸陌生人。所以提示要照实说。
    func sendLoginCode(email: String) async throws {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.contains("@") else { throw AccountError.missingFields }
        _ = try await post("/api/send_code", ["email": target])
    }

    /// 验证码登录。成功就存下 token 并拉一次资料。
    func signIn(email: String, code: String) async throws {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.contains("@"), !pin.isEmpty else { throw AccountError.missingFields }
        let json = try await post("/api/verify", ["email": target, "code": pin])
        try adopt(json)
        await afterSignIn()
    }

    /// App 里点 QQ 登录时要打开的那一页（内置浏览器）。
    ///
    /// `?app=1` 是给服务端的暗号：**这一次跳完要回 App**（`aevis://login?token=…`），
    /// 不是回网页登录页 —— 不然用户就被丢在浏览器里出不来了。
    func qqLoginURL() -> URL? {
        URL(string: base + "/api/qq/start?app=1")
    }

    // MARK: - 用注册码注册（也在 App 里做完，不用去网页）
    //
    // 两步，跟服务端一致：① 注册码 + 邮箱 → 服务器发验证码（**这一步不消费注册码**，
    // 邮箱写错、没收到信都能重来）；② 邮箱验证码 → 建号、这时才把注册码吃掉 → 直接给登录态。

    /// 第一步：验注册码，让服务器给这个邮箱发验证码。
    func registerStart(code: String, email: String) async throws {
        let invite = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !invite.isEmpty, target.contains("@") else { throw AccountError.missingFields }
        _ = try await post("/api/register/start", ["code": invite, "email": target])
    }

    /// 第二步：验证码 + 注册码 → 建号并直接登录。
    func registerFinish(code: String, email: String, emailCode: String) async throws {
        let invite = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = emailCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !invite.isEmpty, target.contains("@"), !pin.isEmpty else {
            throw AccountError.missingFields
        }
        let json = try await post("/api/register/finish",
                                 ["code": invite, "email": target, "email_code": pin])
        try adopt(json)
        await afterSignIn()
    }

    /// 「我的资料」改名 → 推到账号上。
    ///
    /// ⚠️ 服务端**只认这几个键**（`nickname` / `account_no`），多传的会被忽略；
    ///    传 `nickname` 就是只改昵称，不会顺手动别的。
    @MainActor
    @discardableResult
    func pushNickname(_ nickname: String) async throws -> Profile {
        let json = try await post("/api/me/profile", ["nickname": nickname])
        let fresh = Self.profile(from: (json["profile"] as? [String: Any]) ?? json)
        profile = fresh
        return fresh
    }

    /// 换头像：压到 512 传上去（服务端收 **base64 的 JSON**，不收 multipart）。
    ///
    /// ⚠️ `@MainActor`：里面会改 `@Published profile`，而 `await` 回来之后
    ///    线程是随机的 —— 不在主线程上改 `@Published` 在 iOS 26 上会硬崩。
    @MainActor
    @discardableResult
    func uploadAvatar(_ image: UIImage) async throws -> Profile {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
            throw AccountError.badResponse("这张图压不出来，换一张试试。")
        }
        let json = try await post("/api/me/avatar", ["image": jpeg.base64EncodedString()])
        let fresh = Self.profile(from: (json["profile"] as? [String: Any]) ?? json)
        profile = fresh
        return fresh
    }

    /// 把账号上的资料落到**本地**（`ProfileStore`）。
    ///
    /// 为什么还要落一份：朋友圈、聊天那些地方读的都是 `ProfileStore`（本地 UIImage），
    /// 它们不联网、也不该为了显示一个头像去请求服务器。
    /// 顺手把头像下载下来缓存 —— 这样断网时头像也不会变成空白。
    @MainActor
    func applyToLocalProfile() async {
        guard let me = profile else { return }
        let nick = me.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nick.isEmpty, ProfileStore.shared.nickname != nick {
            ProfileStore.shared.nickname = nick
        }
        guard let url = avatarURL else { return }
        // 已经缓存过同一张就别反复下（URL 里带文件名，换了图名字就变）
        if let stamp = avatarCacheStamp, stamp == url.absoluteString { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                ProfileStore.shared.setAvatar(image)
                avatarCacheStamp = url.absoluteString
            }
        } catch {
            // 下载失败不算错：本地那份旧的照用，界面上还是他自己的头像。
        }
    }

    /// 已经缓存到本地的账号头像是哪一张（存 URL，不是图）。
    private var avatarCacheStamp: String? {
        get { UserDefaults.standard.string(forKey: "aevis.accountAvatarStamp") }
        set { UserDefaults.standard.set(newValue, forKey: "aevis.accountAvatarStamp") }
    }

    // MARK: - 登录成功之后统一要做的三件事

    /// 三条登录路（验证码 / 密码 / 注册码 / QQ）**收尾都调它**，别再各写一遍。
    ///
    /// 以前每条路各写各的，结果就是"有的路会拉资料、有的不会" ——
    /// 用户看到的现象就是「头像和名称获取不了」。一处收口最省心。
    @MainActor
    func afterSignIn() async {
        await refreshProfile()
        await applyToLocalProfile()
        await bindThisDevice()
    }

    /// 把**这台设备**绑到刚登录的账号上（`/api/device/bind`）。
    ///
    /// 用户 2026-09-28：「设备码的话，就是也不是绑定账号吗？」
    /// 绑上之后这台机器就跟账号挂钩了：换机要审批、封设备能连账号一起治 ——
    /// 这是反白嫖那条线。**失败不报错**：绑不上不影响他用 App，
    /// 而且服务端本来就有「一台设备只能绑一个账号」的规矩（409 也是正常的）。
    @MainActor
    func bindThisDevice() async {
        let code = DeviceIdentity.wireCode
        guard !code.isEmpty else { return }
        _ = try? await post("/api/device/bind", ["device_id": code])
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
            // ⚠️ **`message` 优先，不是 `error`**：服务端回的是
            //    `{"error":"bad_email","message":"这个邮箱地址看起来不对。"}` ——
            //    给用户看 `error` 那种机器码（bad_email）等于什么都没说，
            //    界面上就是"改了没反应，只蹦一句英文"。中文那句才是人看的。
            let serverSaid = (json?["message"] as? String)
                ?? (json?["error"] as? String)
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
            return "该填的还没填完。"
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
