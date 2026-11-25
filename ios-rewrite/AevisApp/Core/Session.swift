import Foundation
import Security

/// 会话（2026-11-17，134；133 增强）：token 存 Keychain，邮箱/uid 存 UserDefaults。
///
/// 冷启动自动校验 token（`/v1/me`）：失效（401/403）就清掉登录态回到登录页，
/// 网络失败等其它错误一律保留登录态（离线可用）。登录后统一走 `applyLogin`
/// 顺带把云端聊天记录静默恢复到本机。
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var token: String?
    @Published private(set) var email: String = UserDefaults.standard.string(forKey: "email") ?? ""
    /// 冷启动校验中：UI 可据此显示占位，避免"假登录"闪烁。
    @Published private(set) var validating = false
    /// 当前登录用户的头像（相对路径或绝对 URL，空 = 没设）。ChatView「我」的气泡用它。
    /// 来源：`/v1/me` 的 avatar（登录/冷启动校验时顺手取）。
    @Published private(set) var avatar: String = ""

    private let service = "com.aevis.app"
    private let account = "token"

    private init() {
        token = Keychain.read(service: service, account: account)
        // 冷启动自动校验一次；不用改 AevisApp.swift（仅为读 token 决定根视图）。
        Task { await validateOnLaunch() }
    }

    // MARK: - 保留的旧接口（兼容其它文件调用）

    func save(token: String, email: String) {
        Keychain.write(service: service, account: account, value: token)
        UserDefaults.standard.set(email, forKey: "email")
        self.token = token
        self.email = email
    }

    func signOut() {
        Keychain.delete(service: service, account: account)
        self.token = nil
        self.avatar = ""
    }

    // MARK: - 新增

    /// 从 `/v1/me` 的返回里取头像（`avatar` 相对路径或绝对 URL）。尽力而为，不抛错。
    private func syncAvatar(from json: [String: Any]) {
        // request() 已把 data 信封的键补到顶层，也兼容 data 里嵌套的情况
        let d = (json["data"] as? [String: Any]) ?? json
        let a = (d["avatar"] as? String) ?? (json["avatar"] as? String) ?? ""
        if a != avatar { Task { @MainActor in self.avatar = a } }
    }

    /// 换头像成功后同步到全局（首页问候区/聊天「我」的头像都读 `Session.avatar`）。
    /// `avatar` 是 `private(set)`，外部只能通过这个方法改。
    func applyAvatar(_ path: String) {
        guard avatar != path else { return }
        Task { @MainActor in self.avatar = path }
    }

    /// 冷启动校验：本地有 token 才校验。只有明确的 401/403 才登出；
    /// 其它错误（断网、超时、解析失败、5xx）保留登录态，保证离线可用。
    ///
    /// 额外：若当前选中线路失败（尤其自签「直连」SSL 失败），自动探测并切到下一条
    /// 可用线路，然后重试一次 —— 避免用户存过 `direct` 后全盘卡死。
    func validateOnLaunch() async {
        guard let token, !token.isEmpty else { return }
        await MainActor.run { self.validating = true }
        defer { Task { @MainActor in self.validating = false } }

        // 先做一次线路自愈（direct 失败自动切走）。这里只在 ping 不通时切换，
        // 不阻塞太久：probe 是 2s 超时、只探当前一条。
        await healActiveLineIfNeeded()

        do {
            let json = try await APIClient.me(token: token)
            syncAvatar(from: json)
            NSLog("[Session] cold-start token valid")
        } catch {
            var shouldSignOut = false
            if let apiErr = error as? APIError, case let .http(code, _) = apiErr {
                shouldSignOut = (code == 401 || code == 403)
            }
            if shouldSignOut {
                NSLog("[Session] token invalid (401/403), signOut")
                await MainActor.run { self.signOut() }
            } else {
                // 网络失败 / 5xx / 解码失败：不当作掉签，保留本地登录态
                NSLog("[Session] me failed, keep login: \(error.localizedDescription)")
            }
        }
    }

    /// 登录成功统一入口：先落本地登录态，取头像，再**探测**云端备份是否需要恢复。
    /// 不再静默直接恢复 —— 由 CloudBackup 置 `pendingRestore`，UI 弹确认框由用户决定。
    /// 所有登录方式（验证码 / 密码 / 注册 / 微信 / QQ / 扫码）都应改调它。
    func applyLogin(token: String, email: String) async {
        save(token: token, email: email)
        // 取头像（登录态刚拿到，顺便拉一次 me；失败不影响登录）
        if let json = try? await APIClient.me(token: token) { syncAvatar(from: json) }
        // 只探测、不落盘：检测到云端有数据就标记「待确认」，由 ChatListView 弹框
        await CloudBackup.shared.probeForRestoreConfirm(token: token, email: email)
    }

    /// 手动刷新头像（头像设置页/登录后补拉）。供 ChatView 在没有头像时兜底调用。
    func refreshAvatar() async {
        guard let token, !token.isEmpty else { return }
        if let json = try? await APIClient.me(token: token) { syncAvatar(from: json) }
    }

    // MARK: - 线路自愈（解决「存过 direct 就全盘 SSL 失败」）

    /// 探测当前线路：不通就按顺序切到下一条可用线（跳过 certFailed/超时/空地址）。
    /// 只用 APIClient 现有 `probe`/`setActiveLine`/`lines`，不新增 APIClient 依赖。
    /// 返回是否发生了切换。probe 单条 2s×3，为免登录卡顿这里**只探当前一条**，
    /// 不通再逐条探下一条（最多 3 条）。
    @discardableResult
    func healActiveLineIfNeeded(force: Bool = false) async -> Bool {
        let current = APIClient.activeLine
        // 非强制（冷启动）时：只对「自签直连」做探测 —— 普通 HTTPS 线路几乎不会坏，
        // 每次登录都探 6s 会明显拖慢启动。direct 才是已知会 SSL 失败的那条。
        if !force && !current.pinning {
            return false
        }
        if case .ok(_) = await APIClient.probe(current) {
            APIClient.clearLineFailed(current.id)   // 探测通过：解除降权
            return false                             // 当前线可用，不动
        }
        // 当前线不可用（direct 自签 SSL 失败 / 超时 / 空）：记失败降权，按回落顺序找下一条能用的
        APIClient.markLineFailed(current.id)
        for line in APIClient.lines where line.id != current.id && !line.base.isEmpty {
            if case .ok(_) = await APIClient.probe(line) {
                APIClient.setActiveLine(line.id)
                APIClient.lastSwitchNote = "当前线路不可用，已切到 \(line.name)"
                NSLog("[Session] healed line: \(current.name) -> \(line.name)")
                return true
            }
        }
        NSLog("[Session] all lines down, keep \(current.name)")
        return false
    }
}

enum Keychain {
    static func write(service: String, account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // AfterFirstUnlock：设备重启解锁一次后即可读，后台也能拿到 token。
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
