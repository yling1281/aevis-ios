import Foundation

/// 屏幕使用时间。
///
/// **我们自己取不到**：这数据属于苹果的「家庭控制」（Family Controls），
/// 要单独的权限，而现在这张签名里没有；而且没权限时调它的框架不是返回
/// 「没权限」，是**直接崩**。所以一行 API 都不调。
///
/// 改走另一条路 —— **让快捷指令帮我们取，再把结果发回来**：
///
/// 1. 在「快捷指令」里做一个流程（自己看屏幕使用时间、手填、或用能取到的方式）
/// 2. 最后加一步「打开 URL」，填：
///        `aevis://screentime?minutes=213&top=微信,抖音,浏览器`
/// 3. 数据就到这儿了，她会一直记得，也能随口说出来
///
/// 这条路能成立的关键，是 App 注册了 `aevis://` 这个 scheme，
/// 并且实现了 `AevisBridge` 去接收 —— 没有那一步，快捷指令的输出**传不回来**
/// （`shortcuts://run-shortcut` 是没有返回值的）。
final class ScreenTimeInsight: ObservableObject {
    static let shared = ScreenTimeInsight()

    struct Snapshot: Codable, Equatable {
        var minutes: Int
        var top: [String]
        var receivedAt: Date
    }

    @Published private(set) var latest: Snapshot?
    @Published var statusLine: String?

    private static let key = "aevis.screenTimeSnapshot"

    private init() {
        load()
    }

    var hasData: Bool {
        latest != nil
    }

    /// 界面上那个状态字。
    var label: String {
        guard let latest else { return "还没收到数据" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "\(Self.duration(latest.minutes))（\(formatter.string(from: latest.receivedAt))）"
    }

    static let explanation = """
    这个数据我们自己取不到 —— 它属于苹果的「家庭控制」，要单独的权限。
    做法是让**快捷指令**帮你取，最后加一步「打开 URL」填：
    aevis://screentime?minutes=213&top=微信,抖音
    收到之后她会一直记得，你问她「我今天刷了多久手机」她能答上来。
    """

    // MARK: - 收数据

    /// 被 `AevisBridge` 调用。返回一句给用户看的话。
    static func ingest(_ params: [String: String]) -> String {
        let raw = params["minutes"] ?? params["min"] ?? "0"
        let minutes = Int(Double(raw) ?? 0)
        guard minutes > 0 else {
            return "没看懂这个数字（minutes=\(raw)），应该是总分钟数。"
        }

        let top = (params["top"] ?? params["apps"] ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let snapshot = Snapshot(minutes: minutes, top: Array(top.prefix(8)), receivedAt: Date())
        shared.store(snapshot)
        return "收到屏幕使用时间：\(duration(minutes))。"
    }

    private func store(_ snapshot: Snapshot) {
        latest = snapshot
        statusLine = "收到一条屏幕使用时间数据。"
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        latest = decoded
    }

    func clear() {
        latest = nil
        statusLine = "已清掉屏幕使用时间的数据。"
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    // MARK: - 给她用

    /// 喂给模型的一段话。没有数据就返回空。
    func digest() -> String {
        guard let latest else { return "" }
        var text = "对方今天的屏幕使用时间：\(Self.duration(latest.minutes))"
        if !latest.top.isEmpty {
            text += "，用得最多的是：\(latest.top.joined(separator: "、"))"
        }
        return text
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) 分钟" }
        if rest == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(rest) 分钟"
    }
}
