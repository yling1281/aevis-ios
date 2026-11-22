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
    }

    // MARK: - 新增

    /// 冷启动校验：本地有 token 才校验。只有明确的 401/403 才登出；
    /// 其它错误（断网、超时、解析失败、5xx）保留登录态，保证离线可用。
    func validateOnLaunch() async {
        guard let token, !token.isEmpty else { return }
        await MainActor.run { self.validating = true }
        defer { Task { @MainActor in self.validating = false } }

        do {
            _ = try await APIClient.me(token: token)
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

    /// 登录成功统一入口：先落本地登录态，再静默恢复云端聊天记录。
    /// 所有登录方式（验证码 / 密码 / 注册 / 微信 / QQ / 扫码）都应改调它。
    func applyLogin(token: String, email: String) async {
        save(token: token, email: email)
        await CloudBackup.shared.restoreIfNeeded(token: token, email: email)
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
