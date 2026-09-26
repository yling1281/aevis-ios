import Foundation
import SwiftUI
import UIKit

/// 管理端的全部状态。一个类管到底 —— 这个 App 只有一个人用，
/// 拆成一堆小 Store 只会让「刷新」变成一件要协调好几处的事。
///
/// ⚠️ **整个类是 `@MainActor` 的**。所有网络调用都通过 `AdminAPI`
/// 那些 nonisolated 的 static 函数 —— `await` 它们时会自动跑到后台，
/// 回来再在主线程上改 `@Published`。别在这里写 `Task.detached`。
@MainActor
final class AdminStore: ObservableObject {
    static let shared = AdminStore()

    // MARK: 登录态

    @Published private(set) var token: String?
    @Published private(set) var signedInEmail: String = ""

    /// 服务器地址 —— 跟着 `AdminAPI.base` 走，登录页可改。
    @Published var base: String = AdminAPI.base

    var isSignedIn: Bool { token != nil }

    // MARK: 数据

    @Published var stats: AdminStats?
    @Published var users: [AdminUser] = []
    @Published var admins: [String] = []
    @Published var codes: [AdminCode] = []
    @Published var codeStats: AdminCodeStats?
    @Published var deviceRequests: [DeviceRequest] = []
    @Published var blockedUsers: [BlockedUser] = []
    @Published var blockedDevices: [BlockedDevice] = []
    @Published var diag: [DiagReport] = []
    @Published var bot: BotInfo?
    @Published var accountInfo: AdminAccountInfo?

    // MARK: 界面状态

    @Published var loading = false
    @Published var busy = false
    @Published var errorText: String?
    @Published var toast: String?
    @Published var refreshedAt: Date?

    /// 崩溃现场里已经打开了详情的那一条。
    @Published var openDiag: DiagDetail?
    @Published var openDiagAskers: [DiagAsker] = []
    @Published var diagDetailLoading = false

    /// 换机申请里已经展开的那条。
    @Published var openRequest: DeviceRequest?

    private let tokenAccount = "admin.token"
    private let emailKey = "aevis.admin.email"

    private init() {
        // 钥匙串里要是已经有令牌，就直接进去 —— 不用每次重登。
        //
        // ⚠️ 这件事**必须放在这里**，不要写成 App 里的 `.task { store.restore() }`：
        // `.task` 的闭包**不是主 actor 隔离的**，而 `restore()` 是这个
        // `@MainActor` 类的方法 —— 从那儿调要么编译不过（得补 await），
        // 要么得绕一层 `MainActor.run`。放在 init 里成本是零。
        if let saved = Keychain.get(tokenAccount), !saved.isEmpty {
            token = saved
            signedInEmail = UserDefaults.standard.string(forKey: emailKey) ?? ""
        }
    }

    // MARK: - 登录

    func signIn(username: String, password: String) async {
        errorText = nil
        loading = true
        defer { loading = false }
        do {
            let reply: LoginReply = try await AdminAPI.call(
                "/api/admin/login", method: "POST",
                body: ["username": username, "password": password]
            )
            guard let fresh = reply.token, !fresh.isEmpty else {
                errorText = "服务器没给令牌，可能还没设过后台账号密码。"
                return
            }
            token = fresh
            signedInEmail = reply.email ?? username
            Keychain.set(fresh, for: tokenAccount)
            UserDefaults.standard.set(signedInEmail, forKey: emailKey)
            await refreshAll()
        } catch {
            errorText = describe(error)
        }
    }

    func signOut() {
        token = nil
        signedInEmail = ""
        Keychain.remove(tokenAccount)
        UserDefaults.standard.removeObject(forKey: emailKey)
        stats = nil
        users = []
        codes = []
        deviceRequests = []
        blockedUsers = []
        blockedDevices = []
        diag = []
        bot = nil
        accountInfo = nil
        openDiag = nil
    }

    /// 服务器地址改了 → 存下来，顺手要求重登（换服务器了，旧的令牌没意义）。
    func updateBase(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != AdminAPI.base else { return }
        AdminAPI.base = trimmed
        base = AdminAPI.base
        signOut()
    }

    // MARK: - 拉数据

    func refreshAll() async {
        guard isSignedIn else { return }
        loading = true
        defer {
            loading = false
            refreshedAt = Date()
        }

        if let fresh = await get("/api/admin/stats", as: AdminStats.self) { stats = fresh }

        if let list = await get("/api/admin/users", as: AdminUserList.self) {
            users = list.items ?? []
            admins = list.admins ?? []
        }
        if let list = await get("/api/admin/codes", as: AdminCodeList.self) {
            codes = list.items ?? []
            codeStats = list.stats
        }
        if let list = await get("/api/admin/device_requests", as: DeviceRequestList.self) {
            deviceRequests = list.items ?? []
        }
        if let reply = await get("/api/admin/blocks", as: BlocksReply.self) {
            blockedUsers = reply.users ?? []
            blockedDevices = reply.devices ?? []
        }
        if let list = await get("/api/admin/diag", as: DiagReportList.self) {
            diag = list.items ?? []
        }
        if let info = await get("/api/admin/bot", as: BotInfo.self) { bot = info }
        if let me = await get("/api/admin/account", as: AdminAccountInfo.self) {
            accountInfo = me
            if let mail = me.email, !mail.isEmpty { signedInEmail = mail }
        }
    }

    // MARK: - 崩溃现场

    func loadDiagDetail(code: String, deviceId: String) async {
        diagDetailLoading = true
        openDiag = nil
        openDiagAskers = []
        defer { diagDetailLoading = false }

        let encodedCode = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? code
        let encodedDevice = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        if let reply = await get(
            "/api/admin/diag/detail?code=\(encodedCode)&device_id=\(encodedDevice)",
            as: DiagDetailReply.self
        ) {
            openDiag = reply.item
        }
        if let list = await get("/api/admin/diag/askers?code=\(encodedCode)", as: DiagAskerList.self) {
            openDiagAskers = list.items ?? []
        }
    }

    /// 后台点「已反馈」—— 之后机器人会在那个人下次说话时告诉他。
    func markFeedback(code: String, note: String) async {
        await post("/api/admin/diag/feedback", ["code": code, "note": note],
                   done: "已标记反馈，机器人下次会告诉他")
    }

    // MARK: - 账号

    func blockUser(_ email: String, blocked: Bool, reason: String = "") async {
        await post("/api/admin/block_user",
                   ["email": email, "blocked": blocked, "reason": reason],
                   done: blocked ? "已封号" : "已解封")
    }

    func deleteUser(_ email: String) async {
        await post("/api/admin/delete_user", ["email": email], done: "账号已删除")
    }

    func blockDevice(_ deviceId: String, blocked: Bool) async {
        await post("/api/admin/block_device", ["device_id": deviceId, "blocked": blocked],
                   done: blocked ? "设备已封" : "设备已解封")
    }

    /// 解绑设备 —— **不是**解封设备。
    ///
    /// 解封 = 把封禁记录删掉（他被挡在门外了）；
    /// 解绑 = 把"这台机器归谁"的登记删掉（他没被拦，只是换了台机器）。
    /// 用户换手机 / 重装系统 / 刷机之后卡住，要用的就是后者；
    /// 而且解绑会把「一机一号」的占用释放掉，否则那台机器会被一个
    /// 已经不存在的绑定永远占着，新人绑不上。
    func unbindDevice(_ deviceId: String) async {
        await post("/api/admin/unbind_device", ["device_id": deviceId],
                   done: "已解绑，他下次登录会重新绑定")
    }

    // MARK: - 注册码

    func deleteCode(_ code: String) async {
        await post("/api/admin/delete_code", ["code": code], done: "这一张码已删除")
    }

    /// 发码。返回发出来的那些（登录页要把它显示出来给用户复制）。
    @discardableResult
    func issueCodes(count: Int, note: String) async -> [String] {
        guard isSignedIn else { return [] }
        busy = true
        defer { busy = false }
        do {
            let reply: IssuedCodes = try await AdminAPI.call(
                "/api/admin/issue_codes", method: "POST",
                body: ["count": count, "note": note], token: token
            )
            await refreshAll()
            return reply.codes ?? []
        } catch {
            errorText = describe(error)
            return []
        }
    }

    // MARK: - 换机

    func approveDevice(id: Int, approve: Bool) async {
        await post("/api/admin/approve_device", ["id": id, "approve": approve],
                   done: approve ? "已批准换机" : "已拒绝")
    }

    // MARK: - 后台账号密码

    func saveAdminAccount(username: String, password: String) async -> Bool {
        guard isSignedIn else { return false }
        busy = true
        defer { busy = false }
        do {
            let reply: PlainReply = try await AdminAPI.call(
                "/api/admin/account", method: "POST",
                body: ["username": username, "password": password], token: token
            )
            if reply.ok == false {
                errorText = reply.message ?? "没保存上。"
                return false
            }
            toast = "已保存。以后可以用「\(username)」+ 密码登录。"
            accountInfo = await get("/api/admin/account", as: AdminAccountInfo.self) ?? accountInfo
            return true
        } catch {
            errorText = describe(error)
            return false
        }
    }

    // MARK: - 内部

    private func get<T: Decodable>(_ path: String, as type: T.Type) async -> T? {
        guard let token else { return nil }
        do {
            return try await AdminAPI.call(path, token: token, as: T.self)
        } catch {
            notice(error)
            return nil
        }
    }

    private func post(_ path: String, _ body: [String: Any], done: String) async {
        guard let token else { return }
        busy = true
        defer { busy = false }
        do {
            try await AdminAPI.fire(path, method: "POST", body: body, token: token)
            toast = done
            await refreshAll()
        } catch {
            notice(error)
        }
    }

    /// 出现 401 就直接把人送回登录页 —— 令牌没了，再刷新也是白刷。
    private func notice(_ error: Error) {
        if let failure = error as? AdminAPI.Failure {
            switch failure {
            case .cancelled:
                // 用户切走页面而已。**静默** ——
                // 以前它会弹成"连不上服务器（已取消）"，看着像后台断了，
                // 害得人以为连不上、反复重试（服务端那串连点就是这么来的）。
                return
            case .http(401, _):
                signOut()
                errorText = "登录过期了，重新登录一次。"
                return
            default:
                break
            }
        }
        errorText = describe(error)
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
