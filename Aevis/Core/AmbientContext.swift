import Foundation

/// 从外面喂进来的「环境信息」。
///
/// 这些东西 Aevis 自己拿不到 —— iOS 不让 App 后台读电量、读步数、读你现在在哪儿，
/// 但**快捷指令可以**。所以它跑完之后用 `aevis://` 把结果发回来，存在这里，
/// 她聊天的时候就知道「你现在在外面」「手机快没电了」。
///
/// 每条都有保鲜期：位置和电量一小时后就不准了，日程可以管半天。
/// 过期的不再喂给她 —— 不然她会拿着一周前的「你在公司」跟你说话。
final class AmbientContext: ObservableObject {

    static let shared = AmbientContext()

    struct Entry: Codable, Identifiable, Equatable {
        var kind: String
        var text: String
        var updatedAt: Date

        var id: String { kind }
    }

    /// 认得的几类信息。顺序就是界面上列出来的顺序。
    ///
    /// `life` 是保鲜期（秒），`example` 是界面上给用户抄的地址。
    static let kinds: [(key: String, label: String, life: TimeInterval, example: String)] = [
        ("location", "位置", 2 * 3600,
         "aevis://location?name=公司&lat=39.90&lon=116.40"),
        ("battery", "电量", 1 * 3600,
         "aevis://battery?level=57&charging=1"),
        ("focus", "专注模式", 2 * 3600,
         "aevis://focus?on=1"),
        ("steps", "步数", 6 * 3600,
         "aevis://steps?count=8342"),
        ("weather", "天气", 3 * 3600,
         "aevis://weather?text=北京 晴 26度"),
        ("calendar", "日程", 12 * 3600,
         "aevis://calendar?text=下午三点开会"),
        ("health", "健康", 12 * 3600,
         "aevis://health?text=昨晚睡了6小时，静息心率62"),
        ("device", "其它", 24 * 3600,
         "aevis://device?text=现在在回家的地铁上")
    ]

    @Published private(set) var entries: [Entry] = []
    /// 最近一次收到的时间，界面上显示一下，让她知道这条是新的。
    @Published var statusLine: String?

    private static let key = "aevis.ambientContext"

    private init() {
        load()
    }

    // MARK: - 认得的类型

    static func label(for kind: String) -> String {
        kinds.first { $0.key == kind }?.label ?? kind
    }

    static func lifetime(for kind: String) -> TimeInterval {
        kinds.first { $0.key == kind }?.life ?? 6 * 3600
    }

    // MARK: - 收

    @discardableResult
    func ingest(kind: String, text: String) -> String {
        let name = kind.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "这条没带内容，没记下。" }

        if let index = entries.firstIndex(where: { $0.kind == name }) {
            entries[index].text = value
            entries[index].updatedAt = Date()
        } else {
            entries.append(Entry(kind: name, text: value, updatedAt: Date()))
        }
        store()
        return "记下了\(Self.label(for: name))：\(value.prefix(24))"
    }

    // MARK: - 给她

    /// 还没过期的那些，拼成一行行给模型看。
    func digest() -> [String] {
        let now = Date()
        return entries
            .filter { now.timeIntervalSince($0.updatedAt) < Self.lifetime(for: $0.kind) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { "\(Self.label(for: $0.kind))：\($0.text)（\(Self.age($0.updatedAt))）" }
    }

    var isEmpty: Bool { entries.isEmpty }

    func clear() {
        entries = []
        statusLine = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// 相对时间，比一个干巴巴的时刻更好懂。
    private static func age(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86400)) 天前"
    }

    // MARK: - 存

    private func store() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = saved
    }
}
