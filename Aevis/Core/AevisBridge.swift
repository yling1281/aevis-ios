import Foundation
import SwiftUI

/// 和「快捷指令」之间的**双向**桥。
///
/// 为什么必须双向：iOS 只给了两根方向不同的通道，缺一条就什么都做不了。
///
/// **Aevis → 快捷指令**：`shortcuts://run-shortcut?name=名字`
/// （会跳到快捷指令 App 去执行 —— 所以「锁屏」这种 App 自己做不到的事，
/// 靠"跑一个你做好锁屏动作的快捷指令"就能成立。）
///
/// **快捷指令 → Aevis**：注册一个自己的 scheme（`aevis://`），
/// 用户在做快捷指令时最后加一步「打开 URL」，填 `aevis://...`，
/// 系统就会把数据交回这个 App。**没有这一步，快捷指令的输出永远传不回来**
/// （`run-shortcut` 是没有返回值的）。
///
/// 支持的指令：
/// ```
/// aevis://say?text=到点了该睡了        → 她主动发一条消息
/// aevis://note?text=今天量了体重62.5   → 直接记进长期记忆
/// aevis://screentime?minutes=213&top=微信,抖音,浏览器
///                                     → 屏幕使用时间（她自己取不到）
/// aevis://lock                        → 跑你设置好的「锁屏」快捷指令
/// aevis://shortcut?name=回家开灯       → 跑任意一个快捷指令
/// ```
enum AevisBridge {

    /// 注册在 Info.plist 里的 scheme
    static let scheme = "aevis"

    // MARK: - 解析

    struct Command {
        var host: String
        var params: [String: String]

        /// 第一个参数，方便取 text / name
        var first: String {
            params["text"] ?? params["name"] ?? params["value"] ?? ""
        }
    }

    static func parse(_ url: URL) -> Command? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty else { return nil }

        var params: [String: String] = [:]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                guard let value = item.value else { continue }
                params[item.name.lowercased()] = value
            }
        }
        // 也支持 aevis://say/直接写在路径里 这种写法
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty, params.isEmpty {
            params["text"] = path.removingPercentEncoding ?? path
        }
        return Command(host: host, params: params)
    }

    // MARK: - 处理

    /// 处理一条回传。返回一句给用户看的提示（没有就不显示）。
    @discardableResult
    static func handle(_ url: URL) -> String? {
        guard let command = parse(url) else {
            return "这个链接 Aevis 不认识：\(url.absoluteString)"
        }

        switch command.host {
        case "say":
            let text = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "没带内容，没发出消息。" }
            ChatStore.shared.appendProactive(text)
            return "她发了一条：「\(text.prefix(20))」"

        case "note":
            let text = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "没带内容，没记下来。" }
            MemoryStore.shared.add(text, kind: .fact)
            return "记进长期记忆了。"

        case "screentime":
            return ScreenTimeInsight.ingest(command.params)

        case "lock":
            return ShortcutBridge.lockScreenViaShortcut()

        case "shortcut":
            let name = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "没给快捷指令名字。" }
            return ShortcutBridge.runShortcut(named: name)
                ? "跑了「\(name)」。"
                : "没跑起来，检查快捷指令的名字。"

        default:
            return "不认识的指令：\(command.host)"
        }
    }

    // MARK: - 给用户抄的例子

    /// 界面上直接给用户抄的地址，省得他猜参数怎么写。
    static let examples: [(title: String, url: String, note: String)] = [
        ("让她主动说句话", "aevis://say?text=到点了，该睡了", "快捷指令里最后一步加「打开 URL」，填这个"),
        ("记一件事", "aevis://note?text=今天量了体重 62.5", "直接进长期记忆，她会一直记得"),
        ("把屏幕使用时间给她", "aevis://screentime?minutes=213&top=微信,抖音", "minutes 是总分钟数，top 是你用得最多的几个"),
        ("锁屏", "aevis://lock", "需要先在下面填好「锁屏」快捷指令的名字"),
        ("跑任意快捷指令", "aevis://shortcut?name=回家开灯", "name 要和你做的那个完全一致")
    ]
}
