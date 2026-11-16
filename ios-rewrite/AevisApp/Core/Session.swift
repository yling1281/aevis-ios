import Foundation
import Security

/// 会话（2026-11-17，134）：token 存 Keychain，邮箱/uid 存 UserDefaults。
///
/// ⚠️ 骨架阶段只做「登录一次、杀掉重开还在」；没做 refresh、没做多账号。
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var token: String?
    @Published private(set) var email: String = UserDefaults.standard.string(forKey: "email") ?? ""

    private let service = "com.aevis.app"
    private let account = "token"

    private init() {
        token = Keychain.read(service: service, account: account)
    }

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
