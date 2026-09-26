import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 这台设备的**设备码** —— 用户拿去网页上绑定用的那串东西。
///
/// ## 为什么不用系统 UDID（用户问过这条）
/// iOS **从 7 开始就不给 App 读硬件 UDID** 了，公开 API 里根本没有这个能力。
/// 描述文件（App 包里那份 `embedded.mobileprovision`）里**确实有一份 UDID 列表**
/// （`ProvisionedDevices`），但那是「**允许安装的设备清单**」—— 比如证书上限 100 台，
/// 里面就列着 100 个 UDID，**App 没有任何办法知道自己对应的是哪一个**。
/// 所以唯一可行的做法是 `identifierForVendor`。
///
/// ## 为什么还要存进钥匙串
/// `identifierForVendor` 在「把这台手机上同厂商的 App 全删掉之后重装」时会变。
/// 存进钥匙串之后，**就算它变了，我们照样认得是同一台设备** ——
/// 否则用户重装一次就变成「陌生设备」，得去申请换机（而换机一辈子只有一次）。
///
/// ## 形态
/// 规范形态是 `AEVIS` + 12 位十六进制、**不带短横**（`AEVIS9F2A4C317B3E`）；
/// 给人看的时候加短横（`AEVIS-9F2A-4C31-7B3E`）。
/// ⚠️ 服务端也是这个口径 —— 短横只当分隔符，用户抄的时候少打一个也不会变成"另一台"。
enum DeviceIdentity {

    private static let keychainKey = "aevis.device.code"

    /// 规范形态。第一次取就生成并存进钥匙串，之后永远不变。
    static let canonical: String = load()

    /// 给人看的形态。
    static var pretty: String { format(canonical) }

    /// 网页上绑定的入口 —— 绑定**只在网页上做**，App 里不需要登录。
    /// 域名走 `AevisHosts`，别写死。
    static let bindPage = AevisHosts.accountURL("/me")

    // MARK: - 内部

    private static func load() -> String {
        if let saved = Keychain.get(keychainKey), !saved.isEmpty {
            return saved
        }
        let made = make()
        // ⚠️ 标签是 `for:` 不是 `forKey:` —— 全项目的 Keychain 都是这个签名。
        Keychain.set(made, for: keychainKey)
        return made
    }

    private static func make() -> String {
        var seed = ""
        #if canImport(UIKit)
        seed = UIDevice.current.identifierForVendor?.uuidString ?? ""
        #endif
        if seed.isEmpty { seed = UUID().uuidString }

        var hex = seed.uppercased().filter { $0.isHexDigit }
        // 理论上 UUID 一定够 12 位；不够就补，绝不让它生成出长度不对的码
        while hex.count < 12 { hex += "0" }
        return "AEVIS" + String(hex.prefix(12))
    }

    /// `AEVIS9F2A4C317B3E` → `AEVIS-9F2A-4C31-7B3E`
    static func format(_ canonical: String) -> String {
        guard canonical.hasPrefix("AEVIS"), canonical.count > 5 else { return canonical }
        var rest = String(canonical.dropFirst(5))
        var groups: [String] = []
        while rest.count > 4 {
            groups.append(String(rest.prefix(4)))
            rest = String(rest.dropFirst(4))
        }
        if !rest.isEmpty { groups.append(rest) }
        return "AEVIS-" + groups.joined(separator: "-")
    }
}
