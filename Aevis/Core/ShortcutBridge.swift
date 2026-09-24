import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 系统级桥接：快捷指令、打开别的 App、回主界面。
///
/// 这里有一条**必须讲清楚的边界**：
/// - 「回主界面」iOS **没有公开 API**。所以用系统内部的 `suspend` 选择器兜底，
///   并且**调用前先运行时探测** —— 探测不到就返回 false，界面照实说做不到，
///   绝不因为一次调用把 App 搞崩。
/// - 「锁屏」**做不到**。iOS 不允许 App 主动锁屏（能锁的只有系统自己）。
///   绕法是让用户自己做一个「锁定屏幕」的快捷指令，我们通过 `shortcuts://` 触发它。
enum ShortcutBridge {

    // MARK: - 快捷指令

    /// 这台设备能不能跑快捷指令。
    static var isShortcutsAvailable: Bool {
        guard let url = URL(string: "shortcuts://") else { return false }
        #if canImport(UIKit)
        return UIApplication.shared.canOpenURL(url)
        #else
        return false
        #endif
    }

    /// 跑一个已经做好的快捷指令。
    @discardableResult
    static func runShortcut(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let encoded = trimmed.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics
        ) else { return false }
        return open("shortcuts://run-shortcut?name=\(encoded)")
    }

    /// 打开「快捷指令」App 本身，让用户自己去挑。
    @discardableResult
    static func openShortcutsApp() -> Bool {
        open("shortcuts://")
    }

    /// 打开任意链接（http / 应用 scheme / x-callback-url 都行）。
    @discardableResult
    static func open(_ text: String) -> Bool {
        #if canImport(UIKit)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
        #else
        return false
        #endif
    }

    /// 打开抖音（装了就打开，没装就是 false）。
    @discardableResult
    static func openDouyin() -> Bool {
        if open("snssdk1128://") { return true }
        // 退而求其次：网页版
        return open("https://www.douyin.com")
    }

    // MARK: - 回主界面

    /// 能不能回主界面。用系统内部的 `suspend` 选择器 ——
    /// **先探测再调用**，探测不到就当没有，不冒险。
    static var canGoHome: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.responds(to: NSSelectorFromString("suspend"))
        #else
        return false
        #endif
    }

    /// 把 App 送回后台（也就是回到主界面）。
    ///
    /// 这条走的是系统内部实现，**上架会被拒**。这个 App 是侧载自己用的，
    /// 所以可以用；但一定要保留探测与失败返回，换系统版本时不至于崩。
    @discardableResult
    static func goHome() -> Bool {
        #if canImport(UIKit)
        let selector = NSSelectorFromString("suspend")
        guard UIApplication.shared.responds(to: selector) else { return false }
        UIControl().sendAction(selector, to: UIApplication.shared, for: nil)
        return true
        #else
        return false
        #endif
    }

    // MARK: - 锁屏
    //
    // iOS 不给 App 主动锁屏的能力 —— 能做到的只有系统自己。
    // 但**快捷指令可以**（里面有一个「锁定屏幕」动作），所以绕法是：
    // 让用户做一个叫「锁屏」的快捷指令，我们用 URL scheme 把它跑起来。

    /// 跑用户做好的「锁屏」快捷指令。返回一句给用户看的话。
    static func lockScreenViaShortcut() -> String {
        let name = AppSettings.shared.lockShortcutName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "还没填「锁屏」快捷指令的名字。去设置 →「系统」里填一下。"
        }
        guard isShortcutsAvailable else {
            return "这台设备上跑不了快捷指令。"
        }
        guard runShortcut(named: name) else {
            return "没跑起来 —— 检查快捷指令的名字，或者有没有装「快捷指令」。"
        }
        return "交给「\(name)」了。会跳到快捷指令执行，锁上之后回 Aevis 就行。"
    }

    /// 跑用户做好的「屏幕使用时间」快捷指令。
    /// 数据不是我们取的 —— 是那个快捷指令跑完，再用 `aevis://screentime?...`
    /// 打开回来告诉我们的（见 AevisBridge）。
    static func requestScreenTimeViaShortcut() -> String {
        let name = AppSettings.shared.screenTimeShortcutName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "还没填「屏幕使用时间」快捷指令的名字。"
        }
        guard isShortcutsAvailable else {
            return "这台设备上跑不了快捷指令。"
        }
        guard runShortcut(named: name) else {
            return "没跑起来 —— 检查快捷指令的名字。"
        }
        return "交给「\(name)」了。它跑完会用 aevis:// 把数据发回来。"
    }

    static let lockScreenNote = """
    iOS 不允许 App 主动锁屏，但**快捷指令可以** —— 它里面有一个「锁定屏幕」动作。
    做法：在「快捷指令」里做一个指令，放一个「锁定屏幕」动作，把名字填在上面。
    之后你说一声、或点按钮，就会跳到快捷指令把它执行掉（锁上再回 Aevis 就行）。
    """
}
