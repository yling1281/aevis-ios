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
    /// 「账号」那一栏**两种都收** —— 别让用户去想"我该填哪个"。
    ///
    /// 🔴 2026-10-31：后端换成 4-4 的 `aevis_auth`，路径从 `/api/login` 拆成两条：
    ///    含 `@` 走 `/v1/auth/login/email`，否则走 `/v1/auth/login/phone`。
    ///    老后端那个"一个 `/api/login` 自己分辨"的接口**已经不存在了**。
    func signIn(account: String, password: String) async throws {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else { throw AccountError.missingFields }
        let json: [String: Any]
        if name.contains("@") {
            json = try await post("/v1/auth/login/email",
                                  ["email": name.lowercased(), "password": password,
                                   "device_id": DeviceIdentity.wireCode])
        } else {
            json = try await post("/v1/auth/login/phone",
                                  ["phone": name, "password": password,
                                   "device_id": DeviceIdentity.wireCode])
        }
        try adopt(json)
        // 登录响应里已经带了 email/uid/membership（4-4 的契约），先落进 profile，
        // 再拉一次完整资料补齐昵称/头像。
        profile = profileFrom(json)
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
            let me = try await get("/v1/me")
            profile = profileFrom(me)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 内置浏览器的回调换 token
    //
    // 登录页是在**内置浏览器**里跑的（`WebAuth` → `ASWebAuthenticationSession`）：
    // 收验证码 / 输密码 / 走 QQ 都在那一页完成，页面跳
    // `aevis://login?token=...` 把凭证交回来，这里收下。
    // 输验证码的是系统那一层，**密码不经过我们的代码**。
    //
    // ⚠️ `webLoginURL()` 曾经被删过一次（2026-09-29，当时它只被 `AccountCard`
    //    里一段死代码调用）。**2026-10-13 又加回来了**，但语义完全不同：
    //    现在是老板要的「点登录 → 跳系统 Safari → 网页里登录/注册/扫码 →
    //    登完自动跳回 App」那条路的主入口（见 `webLoginURL()` / `receiveWebLogin(_:)`）。
    //    别把它当成旧代码删掉。

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
            let me = try await get("/v1/me")
            profile = profileFrom(me)
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
        _ = try await post("/v1/auth/email/code", ["email": target])
    }

    /// 验证码登录。成功就存下 token 并拉一次资料。
    func signIn(email: String, code: String) async throws {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.contains("@"), !pin.isEmpty else { throw AccountError.missingFields }
        let json = try await post("/v1/auth/login/email-code",
                                  ["email": target, "code": pin,
                                   "device_id": DeviceIdentity.wireCode])
        try adopt(json)
        profile = profileFrom(json)
        await afterSignIn()
    }

    // MARK: - 扫码登录（**新设备这一侧**，2026-10-03）
    //
    // 老板原话：「如果检测到登录的设备是 iPad，支持手机扫码登录，扫码后就直接同步。」
    //
    // 为什么值得单独做一套：在 iPad 上敲邮箱 → 等邮件 → 敲 6 位验证码，是最容易
    // 半路放弃的一段（iPad 的屏幕键盘本身就难用）。手机扫一下、点一下「同意」就完了。
    //
    // 这里只有**两步**（第三、四步在网页和服务器上，见 `server/account/app.py`
    // 的 `api_device_login_*` 和 `server/account/web/scan.html`）：
    //   ① `newDeviceLoginTicket()`  拿一张票，画成二维码显示出来
    //   ② `pollDeviceLogin(ticket:)` 每两秒问一句"有人批了吗"
    //
    // 🔴 **这个流程里没有任何"本机就能过"的环节**：
    //    本机拿到的 token 是**服务器**在"已登录的手机点了同意"之后才发出来的。
    //    光有一张 ticket 什么都换不到（ticket 只是"请让某个人来批一下"的凭据）。
    //    所以这个页面可以放心地被随便谁看到 —— 包括被人拍照。

    /// 服务器给的二维码内容。
    struct DeviceTicket {
        /// 用来轮询的凭据。
        let ticket: String
        /// **要画成二维码的**那段文字（是一个 `https://…/scan?t=…` 网址）。
        ///
        /// 🔴 故意用**普通 https 网址**而不是自定义 scheme（`aevis://…`）：
        ///    扫它的不一定是 Aevis，**任何手机的原生相机**都要能扫开。
        ///    自定义 scheme 在系统相机里根本不会被识别成链接。
        let scanURL: String
        /// 有效期（秒）。界面拿它做倒计时、也拿它决定轮询什么时候放弃。
        let expiresIn: Int
    }

    enum DeviceLoginStatus {
        case pending
        case approved(email: String, token: String)
    }

    /// ① 要一张二维码的票。
    ///
    /// 🔴 2026-10-31：4-4 的 `aevis_auth` **没有设备扫码登录这套接口**
    ///    （老的 `/api/device/login/new` + `poll` 随老服务一起下线了）。
    ///    这里**明确抛出"不可用"**，让 `ScanLoginView` 显示一句人话并提示改走密码/验证码，
    ///    而不是画一张永远扫不开的二维码 —— 那是最坑人的"看起来能用"。
    @MainActor
    func newDeviceLoginTicket() async throws -> DeviceTicket {
        throw AccountError.server("扫码登录暂不可用（服务端未提供该接口），请用邮箱验证码或密码登录。")
    }

    /// ② 问一句「有人批了吗」。
    @MainActor
    func pollDeviceLogin(ticket: String) async throws -> DeviceLoginStatus {
        throw AccountError.server("扫码登录暂不可用。")
    }

    /// App 里点 QQ 登录时要打开的那一页（内置浏览器）。
    ///
    /// 🔴 2026-10-31：4-4 改成**先 POST 换授权地址**（`POST /v1/auth/qq/url`
    ///    → `{auth_url, state}`），不再有"直接 GET `/api/qq/start` 就跳走"那种接口。
    ///    所以这个方法从同步变成了 `async`。
    ///
    /// ⚠️ 当前 4-4 的 `.env` 里**没有 `AEVIS_QQ_APP_ID`**，调用会拿到
    ///    "QQ 登录未配置"，这里回 nil，界面提示用户先用邮箱登录。
    ///    等后台把 QQ 互联的 AppID/AppKey 配上，这个入口自动就通了。
    func qqLoginURL() async -> URL? {
        do {
            let json = try await post("/v1/auth/qq/url", ["redirect_uri": "aevis://login"])
            guard let raw = json["auth_url"] as? String, !raw.isEmpty,
                  let url = URL(string: raw) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    /// App 里点「登录 / 注册」时要打开的那一页（**系统浏览器 Safari**）。
    ///
    /// `?app=1` 是给服务端的暗号：这一轮走完之后要跳回 App
    /// （`aevis://login?token=…`），而不是把用户留在网页上。
    func webLoginURL() -> URL? {
        guard isConfigured else { return nil }
        // 🔴 2026-10-31：4-4 没有 `/login` 这个页面（那个路径被 nginx 兜成官网首页了，
        //    返回 200 但是 HTML 首页，看起来"能打开"其实什么都不是）。
        //    真正的账号网页是 `/account.html`。它**不会**回跳 `aevis://`
        //    —— 所以 LoginView 的主按钮已经改成在 App 内登录，这里只留作保底入口。
        return URL(string: webRoot + "/account.html")
    }

    /// 把「接口根」还原成「人看的网页根」。
    ///
    /// 接口根带一段随机前缀（`https://account.aevis.cn/k5stbt2o`），
    /// 那前缀**只给 `/api/…` 用** —— 服务器上根本没有带前缀的 `/login`
    /// （`AevisHosts` 的注释里就写着"带前缀的 /me 服务器上根本不存在"）。
    /// 所以这里把已知前缀剥掉。线路三本来就不带前缀，剥不到、原样返回。
    ///
    /// ⚠️ 按 `AevisHosts.apiPath` 这个**值**剥，不是按固定位置切 ——
    ///    前缀以后改了这里跟着走，不用改两处。
    private var webRoot: String {
        var text = base
        let prefix = AevisHosts.apiPath
        if !prefix.isEmpty, text.hasSuffix(prefix) {
            text.removeLast(prefix.count)
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    /// 网页把凭证带回来了（`aevis://login?token=…`）。
    ///
    /// 走**真 Safari** 那条路时，回跳不经过 `ASWebAuthenticationSession`，
    /// 而是系统的 URL scheme 唤起（`RootView.onOpenURL`）—— 所以必须在这里收。
    /// 返回 `nil` 表示成功；否则是给用户看的一句话。
    @MainActor
    func receiveWebLogin(_ url: URL) async -> String? {
        let params = url.queryParameters
        let token = (params["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            do {
                try await adoptWebToken(token)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        return AccountService.loginFailureText(params["qq_error"] ?? params["error"])
    }

    /// 网页没把 token 带回来时，把它给的原因翻成人话。
    ///
    /// ⚠️ 原来这段长在 `LoginView` 里（`qqFailureText`）。现在**两条路都要用**
    ///    （App 内置浏览器那条 ＋ 真 Safari 这条）⇒ 提到这里当唯一实现。
    static func loginFailureText(_ code: String?) -> String {
        switch code {
        case nil:
            return "授权没走完，再点一次试试。"
        case "not_configured":
            return "服务器上还没配好 QQ 登录，先用别的邮箱登录吧。"
        case "state_expired":
            return "这次授权过期了，再点一次。"
        case "blocked":
            return "这个账号已被停用，有疑问联系管理员。"
        case let other?:
            return "登录失败（\(other)），换个方式登录吧。"
        }
    }

    // MARK: - 注册（2026-10-31 重写）
    //
    // 🔴 老流程是「注册码（群里机器人发的一人一码）+ 邮箱验证码」，**已经废弃**：
    //    4-4 的 `aevis_auth` 走的是「邮箱 + 密码 + 邮箱验证码」，没有邀请码这个概念。
    //    新流程两步，跟服务端一致：
    //      ① `requestRegisterCode(email:)` → `POST /v1/auth/email/code` 发码
    //      ② `register(email:password:code:)` → `POST /v1/auth/register` 建号并直接给登录态

    /// 第一步：给这个邮箱发注册验证码。
    ///
    /// ⚠️ 4-4 的 `/v1/auth/email/code` 对**没注册过的邮箱**也发（注册和登录共用这一个端点），
    ///    所以这里不需要先判断"这个邮箱是不是已存在" —— 已存在的话第二步会明确告诉用户。
    func requestRegisterCode(email: String) async throws {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard target.contains("@") else { throw AccountError.missingFields }
        _ = try await post("/v1/auth/email/code", ["email": target])
    }

    /// 第二步：邮箱 + 密码 + 验证码 → 建号并直接登录。
    ///
    /// 密码策略在**本地先挡一次**（≥8 位、同时含字母和数字）：
    /// 服务端也校验，但让用户填完验证码才被退回"密码太简单"是很糟的体验 ——
    /// 验证码还白白烧掉一次。
    func register(email: String, password: String, code: String) async throws {
        let target = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pin = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.contains("@"), !pin.isEmpty else { throw AccountError.missingFields }
        guard password.count >= 8,
              password.rangeOfCharacter(from: .letters) != nil,
              password.rangeOfCharacter(from: .decimalDigits) != nil else {
            throw AccountError.server("密码至少 8 位，并且要同时包含字母和数字。")
        }
        let json = try await post("/v1/auth/register",
                                  ["email": target, "password": password, "code": pin])
        try adopt(json)
        await afterSignIn()
    }

    /// 「我的资料」改名 → 推到账号上。
    ///
    /// 🔴 2026-10-31：4-4 的 `POST /v1/me/profile` 只回 `{ok,uid,nickname,avatar}`，
    ///    **不带 email / 会员**（老后端回的是 `{"profile":{…}}` 整块）。所以改完必须
    ///    再拉一次 `/v1/me`，否则 profile 被这份"残缺响应"覆盖后，
    ///    界面上邮箱和到期日会凭空消失。
    @MainActor
    @discardableResult
    func pushNickname(_ nickname: String) async throws -> Profile {
        _ = try await post("/v1/me/profile", ["nickname": nickname])
        await refreshProfile()
        return profile ?? Profile(id: "", username: settings.accountEmail,
                                  nickname: nickname, accountNo: "", avatar: "",
                                  expiresAt: nil)
    }

    /// 换头像。
    ///
    /// 🔴 2026-10-31：4-4 的 `aevis_auth` **没有图片上传接口** —— `avatar` 只是个
    ///    字符串字段，没有收文件/收 base64 的端点（老后端那个 `POST /api/me/avatar`
    ///    已随老服务下线）。这里**显式报错**，不静默假装成功：假装成功的话
    ///    用户以为换好了，下次登录又变回去，比直接说"不支持"糟糕得多。
    @MainActor
    @discardableResult
    func uploadAvatar(_ image: UIImage) async throws -> Profile {
        throw AccountError.server("头像上传暂未开放（服务端还没提供图片存储），昵称可以先改。")
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
                // 服务器上那张就是我们上传时没压过的原图 ⇒ 网络字节直接当原图存一份
                ProfileStore.shared.setAvatar(image, original: data)
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

    /// 把**这台设备**绑到刚登录的账号上。
    ///
    /// 🔴 2026-10-31：4-4 的 `aevis_auth` **没有「设备绑定」这个概念** ——
    ///    登录态只靠 token（`auth_session` 里记 device_id 用于展示），
    ///    不存在"一台设备只能绑一个账号"的老规矩。老后端那个 `/api/device/bind`
    ///    已经跟着老服务一起下线了。
    ///    这里保留空实现（而不是删掉调用点），是为了不让 `afterSignIn` 分叉。
    @MainActor
    func bindThisDevice() async {
        // 无需绑定：新体系里登录即可，设备只是会话上的一个备注字段。
    }

    // MARK: - 登录设备管理（跟微信一样：看几台、把别的踢下线）

    /// 服务器给的「一台登录设备」。字段名跟 `GET /api/devices` 的返回一一对应。
    ///
    /// ⚠️ `deviceID` / `name` **可能是空串**（老 token 认不出是哪台设备）——
    ///    界面碰到空串要显示「未知设备」，别把空字符串当名字摆出来。
    struct DeviceSession: Identifiable, Hashable {
        let deviceID: String
        let name: String
        let userAgent: String
        let ip: String
        /// Unix 秒。**0 = 从没记录过**（不是 1970 年，界面要显示「时间不详」）。
        let lastSeen: Int
        let firstSeen: Int
        let tokenCount: Int
        /// 是不是**本机**。
        let isCurrent: Bool
        /// 列表用的稳定 id：认不出的设备统一收成一个 `__unknown__`。
        var id: String { deviceID.isEmpty ? "__unknown__" : deviceID }
    }

    /// 拉一份「当前账号登着哪些设备」的清单。
    ///
    /// 🔴 2026-10-31：数据源从老后端的 `GET /api/devices`（按设备聚合）
    ///    换成 4-4 的 `GET /v1/auth/sessions`（**按会话/token 列**）。
    ///    差别：新接口一条 = 一次登录，所以 `tokenCount` 恒为 1，
    ///    也拿不到 UA 和"上次在线"——那些字段只能留空，界面显示「未知设备」。
    @MainActor
    func listDevices() async throws -> [DeviceSession] {
        let json = try await get("/v1/auth/sessions")
        let rows = (json["items"] as? [[String: Any]]) ?? []
        let mine = settings.accountToken
        return rows.map { row in
            let token = (row["token"] as? String) ?? ""
            let created = Self.unix(fromISO: (row["created_at"] as? String) ?? "")
            return DeviceSession(
                deviceID: (row["device_id"] as? String) ?? "",
                name: "",
                userAgent: "",
                ip: (row["ip"] as? String) ?? "",
                lastSeen: created,
                firstSeen: created,
                tokenCount: 1,
                isCurrent: !token.isEmpty && token == mine
            )
        }
    }

    /// 把某台设备踢下线。返回服务器说踢掉了几条登录（`revoked`）。
    ///
    /// 🔴 2026-10-31：4-4 的 `aevis_auth` **只有 `POST /v1/auth/logout`（登出自己）**，
    ///    没有"按设备踢下线"的接口。所以：
    ///      · 踢本机 → 走登出，返回 1
    ///      · 踢别人 → 明确报不支持，**不假装踢掉了**
    @MainActor
    @discardableResult
    func revokeDevice(_ deviceID: String) async throws -> Int {
        if deviceID.isEmpty {
            throw AccountError.cannotRevokeCurrent
        }
        throw AccountError.server("暂不支持远程退出其它设备（服务端未提供该接口）。"
                                   + "你可以在那台设备上点「退出账号」。")
    }

    // MARK: - 底层

    private func adopt(_ json: [String: Any]) throws {
        guard let token = json["token"] as? String, !token.isEmpty else {
            // 4-4 失败时不会走到这里（`send` 已经把 `code != 200` 抛成 `.server`）——
            // 能到这儿的只有"200 但没给 token"这种契约不符的情况。
            throw AccountError.badResponse(
                (json["msg"] as? String) ?? (json["error"] as? String)
                    ?? "服务器没给 token（返回里有这些字段："
                    + json.keys.sorted().joined(separator: ",") + "）"
            )
        }
        settings.accountToken = token
        if let expires = json["expires_in"] as? Double {
            settings.accountExpiresAt = Date().timeIntervalSince1970 + expires
        } else if let stamp = json["expires_at"] as? Double {
            settings.accountExpiresAt = stamp
        }
        // 4-4 的登录响应是**扁平的**（没有 `user`/`profile` 包一层）：
        // `{ok,token,uid,email,membership}`。完整 email 只在这里出现一次
        // （`/v1/me` 回的是打码值）→ 顺手存下来给界面用。
        let mail = (json["email"] as? String) ?? ""
        if mail.contains("@"), !mail.contains("***") {
            settings.accountEmail = mail
        }
        if let user = json["user"] as? [String: Any] {
            profile = profileFrom(user)
        } else {
            profile = profileFrom(json)
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
        // 设备身份**所有请求都带**（这是唯一的出口，加在这儿一处就全齐了）：
        // 登录接口也会带上 ⇒ 后端在发 token 时顺手把这台设备落库，
        // 「登录设备」列表里才认得出来。不用逐个改 signIn / adoptWebToken。
        let code = DeviceIdentity.wireCode
        if !code.isEmpty { request.setValue(code, forHTTPHeaderField: "X-Aevis-Device") }
        let friendly = DeviceIdentity.friendlyName
        if !friendly.isEmpty { request.setValue(friendly, forHTTPHeaderField: "X-Aevis-Device-Name") }
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
            // 🔴 2026-10-31：后端换成 4-4 的 `aevis_auth` 后，**所有业务响应都套了一层信封**：
            //     成功 `{"code":200,"data":{…},"msg":"ok"}`
            //     失败 `{"code":4103,"data":null,"msg":"邮箱格式不对"}`
            //   在这里统一拆开，上层（signIn / adopt / profile…）继续按扁平字段取，
            //   不用每个方法都写一遍 `json["data"]`。
            //   ⚠️ 判据是**顶层同时有 `code` 和 `data` 两个键** —— 万一是老式扁平响应
            //      （比如某个本地回落接口）就没有这两个键，原样返回，不影响其他调用点。
            if let code = json["code"] as? Int, json.keys.contains("data") {
                if code == 200 {
                    return (json["data"] as? [String: Any]) ?? json
                }
                let msg = (json["msg"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "请求失败（\(code)）"
                throw AccountError.server(msg)
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

    /// 把一份响应解析成 `Profile`。
    ///
    /// 服务器**三种形状都认**：
    ///   · `{"profile": {…}}` —— 老后端 `/api/me`（已下线，留作兼容）
    ///   · `{"user":    {…}}` —— 老登录接口
    ///   · 字段直接平铺在顶层  —— **4-4 的 `/v1/me` 和 `/v1/auth/login/email` 都是这种**
    ///
    /// 4-4 的差异（2026-10-31）：
    ///   · 主键叫 `uid`（老的是 `id`）
    ///   · `/v1/me` 的 `email` 是**打码**的（`p***@aevis.cn`）→ 回落到本地存的完整邮箱
    ///   · 没有 `account_no`（那 8 位号是老账本特有的）→ 用 uid 顶上，界面有东西可显示
    ///   · 会员信息在 `membership.expire_at` 里，解析成 `expiresAt`
    private func profileFrom(_ json: [String: Any]) -> Profile {
        let user = (json["profile"] as? [String: Any])
            ?? (json["user"] as? [String: Any])
            ?? json
        var email = Self.text(user["email"])
        // 打码值（含 `***`）不能拿来当账号名显示 —— 用登录时存下的完整邮箱。
        if email.contains("***") {
            email = settings.accountEmail
        }
        let uid = Self.text(user["uid"])
        let legacyID = Self.text(user["id"])
        let rawID = uid.isEmpty ? legacyID : uid
        var accountNo = Self.text(user["account_no"])
        if accountNo.isEmpty, uid.isEmpty == false {
            accountNo = uid          // 4-4 没有账号号，用 uid 占位（界面要显示"账号 ID"）
        }
        var expires: Date?
        if let mem = user["membership"] as? [String: Any],
           let stamp = mem["expire_at"] as? String, !stamp.isEmpty {
            expires = Self.date(fromISO: stamp)
        }
        return Profile(
            id: rawID.isEmpty ? email : rawID,
            username: email.isEmpty ? ((user["username"] as? String) ?? "") : email,
            nickname: (user["nickname"] as? String) ?? "",
            accountNo: accountNo,
            avatar: Self.text(user["avatar"]),
            expiresAt: expires
        )
    }

    /// 解析后端给的 ISO 时间（`2026-11-24T09:34:11+00:00` 或 `2026-11-24 18:55:39`）。
    private static func date(fromISO text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        // 4-4 有一部分历史数据是 `YYYY-MM-DD HH:MM:SS`（不带时区，按本地算）
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df.date(from: text)
    }

    /// ISO 时间 → Unix 秒（解析不出来给 0，语义是"时间不详"）。
    private static func unix(fromISO text: String) -> Int {
        guard let d = date(fromISO: text) else { return 0 }
        return Int(d.timeIntervalSince1970)
    }

    private static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? Int { return String(number) }
        if let number = value as? Int64 { return String(number) }
        return ""
    }

    /// 服务器给的数字（`JSONSerialization` 可能解成 Int / Double / String）→ Int。
    /// 解不出就当 0（`last_seen == 0` 的语义本来就是「没记录过」）。
    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
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

/// 扫码登录里"这张二维码不能再用"的四种情况。
///
/// ⚠️ 为什么不复用 `AccountError.http`：那个的错误文案是"服务器返回 410：{...}"，
///    对着用户念状态码等于什么都没说。这里把**每一种情况该怎么做**说清楚 ——
///    用户唯一能做、也唯一需要做的事就是「重新生成一张」。
enum DeviceLoginError: LocalizedError {
    case rejected(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case let .rejected(status, reason):
            switch status {
            case 410: return "二维码过期了，点「重新生成」再来一张。"
            case 404: return "服务器不认这张二维码，点「重新生成」再来一张。"
            case 409: return "这张二维码已经批过了。"
            default: return reason.isEmpty ? "服务器说不可以（\(status)）。" : reason
            }
        }
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
    /// 后端业务错误（4-4 的信封里 `code != 200`）。`msg` 已经是中文人话，直接展示。
    /// 单独一个 case 是为了**不要把 4xxx 业务码显示成 HTTP 状态**（"服务器返回 4103" 很吓人）。
    case server(String)
    /// 想踢的就是**本机** —— 后端拒（400 `cannot_revoke_current`）。
    case cannotRevokeCurrent

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
        case let .server(msg):
            return msg
        case .cannotRevokeCurrent:
            return "这是本机，退出登录请用「退出账号」。"
        }
    }
}

extension URL {
    /// 把 `?a=1&b=2` 拆成字典。QQ 回调 / 网页登录回跳都要用。
    var queryParameters: [String: String] {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}
