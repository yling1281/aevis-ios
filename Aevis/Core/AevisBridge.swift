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
/// 能用的指令：
/// ```
/// ——— 让她做事 ———
/// aevis://say?text=到点了该睡了          她主动发一条消息
/// aevis://ask?text=我今天怎么样           把这句话发给她，她回
/// aevis://note?text=今天量了体重62.5      直接记进长期记忆
/// aevis://music?query=晴天                让她放这首歌
/// aevis://call                           打开实时通话
/// aevis://listen                         打开一起听
/// aevis://daily                          让她看看今天过得怎么样
/// aevis://lock                           跑你设置好的那个「锁屏」快捷指令
/// aevis://shortcut?name=回家开灯          跑任意一个快捷指令
///
/// ——— 把外面的信息告诉她 ———
/// aevis://location?name=公司&lat=39.9&lon=116.4
/// aevis://battery?level=57&charging=1
/// aevis://focus?on=1
/// aevis://steps?count=8342
/// aevis://weather?text=北京 晴 26度
/// aevis://calendar?text=下午三点开会
/// aevis://health?text=昨晚睡了6小时
/// aevis://device?text=现在在回家的地铁上   万能兜底，写什么都行
/// aevis://clearcontext                    清掉上面这些
/// ```
enum AevisBridge {

    /// 注册在 Info.plist 里的 scheme
    static let scheme = "aevis"

    // MARK: - 解析

    struct Command {
        var host: String
        var params: [String: String]

        /// 第一个参数，方便取 text / name / query
        var first: String {
            for key in ["text", "name", "query", "value", "content"] {
                if let value = params[key], !value.isEmpty { return value }
            }
            return ""
        }

        func flag(_ key: String) -> Bool {
            guard let value = params[key]?.lowercased() else { return false }
            return ["1", "true", "yes", "on", "是", "开"].contains(value)
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

        // ——— 让她说话 ———

        case "say":
            let text = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "没带内容，没发出消息。" }
            ChatStore.shared.appendProactive(text)
            return "她发了一条：「\(text.prefix(20))」"

        case "ask":
            let text = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "没带内容，没问她。" }
            BridgeInbox.shared.ask = text
            return "替你问她：「\(text.prefix(20))」"

        case "daily":
            BridgeInbox.shared.ask = "帮我看看今天过得怎么样"
            return "让她说说今天…"

        case "note":
            let text = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "没带内容，没记下来。" }
            MemoryStore.shared.add(text, kind: .fact)
            return "记进长期记忆了。"

        // ——— 让她做事 ———

        case "screentime":
            return ScreenTimeInsight.ingest(command.params)

        case "music":
            let query = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return "没给歌名。" }
            Task { await playMusic(matching: query) }
            return "在找「\(query)」…"

        case "call":
            BridgeInbox.shared.openCall = true
            return "打开通话了。"

        case "listen":
            BridgeInbox.shared.openListen = true
            return "打开一起听了。"

        case "lock":
            return ShortcutBridge.lockScreenViaShortcut()

        case "shortcut":
            let name = command.first.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "没给快捷指令名字。" }
            return ShortcutBridge.runShortcut(named: name)
                ? "跑了「\(name)」。"
                : "没跑起来，检查快捷指令的名字。"

        // ——— 外面的信息 ———

        case "location", "battery", "focus", "steps",
             "weather", "calendar", "health", "device":
            return ingestAmbient(kind: command.host, command: command)

        case "clearcontext":
            AmbientContext.shared.clear()
            return "外面来的信息都清掉了。"

        default:
            return "不认识的指令：\(command.host)"
        }
    }

    // MARK: - 环境信息

    /// 把快捷指令报上来的原始参数拼成人话，再存起来。
    ///
    /// 各家快捷指令拿到的原始值格式不一样（电量有时是 0.57 有时是 57），
    /// 所以这里只做**能确定**的转换，剩下的一律按「原文就是给人看的一句话」处理。
    private static func ingestAmbient(kind: String, command: Command) -> String {
        let params = command.params

        switch kind {
        case "location":
            var parts: [String] = []
            if let name = params["name"], !name.isEmpty { parts.append(name) }
            let lat = params["lat"] ?? params["latitude"] ?? ""
            let lon = params["lon"] ?? params["lng"] ?? params["longitude"] ?? ""
            if !lat.isEmpty, !lon.isEmpty { parts.append("(\(lat), \(lon))") }
            if parts.isEmpty, !command.first.isEmpty { parts.append(command.first) }
            guard !parts.isEmpty else { return "位置没带内容。" }
            return AmbientContext.shared.ingest(kind: kind, text: parts.joined(separator: " "))

        case "battery":
            var parts: [String] = []
            if let raw = params["level"] ?? params["percent"] ?? params["battery"] {
                let value = Double(raw) ?? 0
                // 有些快捷指令拿到的是 0–1，有些是 0–100
                let percent = value <= 1 ? value * 100 : value
                parts.append("\(Int(percent.rounded()))%")
            }
            if let raw = params["charging"] ?? params["state"] {
                let lower = raw.lowercased()
                if ["1", "true", "yes", "on", "charging", "是", "充"].contains(lower) {
                    parts.append("正在充电")
                } else if ["0", "false", "no", "off", "unplugged", "没充"].contains(lower) {
                    parts.append("没在充电")
                }
            }
            if parts.isEmpty, !command.first.isEmpty { parts.append(command.first) }
            guard !parts.isEmpty else { return "电量没带内容。" }
            return AmbientContext.shared.ingest(kind: kind, text: parts.joined(separator: "，"))

        case "focus":
            let on = command.flag("on") || command.flag("enabled")
            return AmbientContext.shared.ingest(
                kind: kind,
                text: on ? "开着专注模式" : "没开专注模式"
            )

        case "steps":
            if let raw = params["count"] ?? params["steps"] ?? params["value"] {
                let value = Int(Double(raw) ?? 0)
                return AmbientContext.shared.ingest(kind: kind, text: "今天走了 \(value) 步")
            }
            return AmbientContext.shared.ingest(kind: kind, text: command.first)

        default:
            // weather / calendar / health / device —— 快捷指令那边已经拼好一句话了
            return AmbientContext.shared.ingest(kind: kind, text: command.first)
        }
    }

    // MARK: - 放歌

    /// 让她放一首歌。没登录就直接说清要先去登录，不装作在放。
    @MainActor
    private static func playMusic(matching query: String) async {
        guard NeteaseClient.shared.isLoggedIn else {
            MusicPlayer.shared.note("网易云还没登录 —— 在「设置 → 音乐」里登录一次就好。")
            return
        }
        do {
            let tracks = try await NeteaseClient.shared.search(query, limit: 1)
            guard let first = tracks.first else {
                MusicPlayer.shared.note("没找到「\(query)」。")
                return
            }
            MusicPlayer.shared.note(nil)
            await MusicPlayer.shared.play([first])
        } catch {
            MusicPlayer.shared.note(error.localizedDescription)
        }
    }

    // MARK: - 给用户抄的例子

    /// 界面上直接给用户抄的地址，省得他猜参数怎么写。
    static let examples: [(title: String, url: String, note: String)] = [
        ("让她主动说句话", "aevis://say?text=到点了，该睡了",
         "快捷指令里最后一步加「打开 URL」，填这个"),
        ("替我问问她", "aevis://ask?text=我今天怎么样",
         "和上面不同：这句是「我说的」，她会回你"),
        ("记一件事", "aevis://note?text=今天量了体重 62.5",
         "直接进长期记忆，她会一直记得"),
        ("让她放首歌", "aevis://music?query=晴天",
         "需要先在「音乐」里登录网易云"),
        ("让她看看今天", "aevis://daily",
         "她会顺着你发过的信息说说今天"),
        ("打开实时通话", "aevis://call", "直接进通话界面"),
        ("打开一起听", "aevis://listen", "直接进一起听"),
        ("锁屏", "aevis://lock", "需要先在下面填好「锁屏」快捷指令的名字"),
        ("跑任意快捷指令", "aevis://shortcut?name=回家开灯", "name 要和那个快捷指令完全一致"),
        ("清掉外面来的信息", "aevis://clearcontext", "位置 / 电量 / 步数这些一并清空")
    ]
}
