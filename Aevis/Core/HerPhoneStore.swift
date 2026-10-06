import Foundation

/// ta"手机"上的一个 App。
///
/// 老板 2026-10 要的：给 ta 弄一部"假手机"，能看见 ta 装了哪些 App。
/// 这里是**纯本地假数据** —— 不联网、不真的装东西，只是把这台虚拟手机
/// 上的图标列表存下来，供界面画出来。
///
/// ⚠️ `symbol` 存的是 **SF Symbol 名**（如 `"message.fill"`）。
///    **绝对不能**存一个运行时不存在、系统画不出来的符号名 ——
///    那种图标会渲染成空白，界面看着像坏了。默认那套已经逐个核对过。
struct HerApp: Identifiable, Codable, Equatable {
    /// 稳定字符串 id。默认 App 用手写 slug（`"wechat"` / `"qq"` …），
    /// 用户装的用 UUID 字符串 —— 名字当 id 的好处是两台设备认出是同一条。
    var id: String
    var name: String
    /// **SF Symbol 名**。见类型注释里那条硬规矩。
    var symbol: String
    var installedAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         symbol: String,
         installedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.installedAt = installedAt
    }
}

/// ta 手机上的一次"动作"（打开了哪个 App）。
///
/// 纯**给眼睛看**的历史记录：界面上拿它做"最近动态"。
/// 真正要让"我"知道的那一条，走的是聊天里的 `.herPhone` 消息。
struct HerPhoneEvent: Identifiable, Codable, Equatable {
    var id: String
    var appName: String
    var action: String
    var at: Date

    init(id: String = UUID().uuidString,
         appName: String,
         action: String,
         at: Date = Date()) {
        self.id = id
        self.appName = appName
        self.action = action
        self.at = at
    }
}

/// ta 的"小手机" —— 装着哪些 App、最近做了什么。**按联系人分开存**。
///
/// 跟待办 / 日记 / 心情一个道理：换个人不该看到上一个人的手机。
/// 切人由 `PersonaStore.broadcastSwitch` 统一通知。
///
/// ⚠️ 新加「按人分开存」的 Store 时，**两件事必须一起做**（漏一个就是 bug）：
///    ① 在 `PersonaStore.broadcastSwitch` / `remove` 里挂号；
///    ② 自己带 `loading` 标志位，并进 `BackupService.stores()`。
///    漏掉 ① 是「换了人还看着上一个的手机」，漏掉 ② 是「搬家搬丢」。
final class HerPhoneStore: ObservableObject {
    static let shared = HerPhoneStore()

    /// 当前联系人 ta 手机上装着的 App。
    @Published private(set) var apps: [HerApp] = []

    /// ta 最近的动作（新的在**后**，界面取 `recentEvents` 反过来看）。
    @Published private(set) var events: [HerPhoneEvent] = []

    /// 每个联系人一份，按 id 归。
    private var appsByOwner: [UUID: [HerApp]] = [:]
    private var eventsByOwner: [UUID: [HerPhoneEvent]] = [:]
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**（同 `TodoStore.loading`）。
    private var loading = false

    /// events 最多留这么多条，超了从**最老的**开始丢（滚动裁剪）。
    static let maxEvents = 200

    private let fileURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-herphone-by-contact.json")
        load()
    }

    // MARK: - 默认那套 App（ta"装"好的）

    /// 首次运行时给 ta 一套默认 App。
    ///
    /// ⚠️ 每个 `symbol` 都是**系统里真有**的 SF Symbol —— 别随手改。
    ///    颜色不在模型里存（模型只有 name/symbol），界面按名字算一个稳定色。
    static let defaultApps: [HerApp] = [
        HerApp(id: "wechat", name: "微信", symbol: "message.fill"),
        HerApp(id: "qq", name: "QQ", symbol: "bubble.left.and.bubble.right.fill"),
        HerApp(id: "taobao", name: "淘宝", symbol: "bag.fill"),
        HerApp(id: "pinduoduo", name: "拼多多", symbol: "cart.fill"),
        HerApp(id: "douyin", name: "抖音", symbol: "music.note"),
        HerApp(id: "xiaohongshu", name: "小红书", symbol: "book.fill"),
        HerApp(id: "meituan", name: "美团", symbol: "fork.knife"),
        HerApp(id: "netease", name: "网易云音乐", symbol: "headphones"),
        HerApp(id: "wangzhe", name: "王者荣耀", symbol: "gamecontroller.fill"),
        HerApp(id: "alipay", name: "支付宝", symbol: "creditcard.fill"),
        HerApp(id: "gaode", name: "高德地图", symbol: "map.fill"),
        HerApp(id: "camera", name: "相机", symbol: "camera.fill")
    ]

    /// 认一个 App 名字对应的 SF Symbol；认不出就给一个通用兜底图。
    ///
    /// 做成静态方法是因为聊天卡片（`HerPhoneBubble`）也要用 ——
    /// 而那条消息只带着 `appName`，不带 symbol。
    static func symbol(for name: String) -> String {
        if let hit = shared.apps.first(where: { $0.name == name }) { return hit.symbol }
        if let hit = defaultApps.first(where: { $0.name == name }) { return hit.symbol }
        return "square.grid.2x2"
    }

    // MARK: - 切人

    func setOwner(_ id: UUID?) {
        stash()
        owner = id
        guard let id else {
            apps = []
            events = []
            return
        }
        // 这个人还没有手机 ⇒ 首次给 ta 装上默认那套。
        // ⚠️ 判空用 `== nil` 而不是 `isEmpty`：用户把 App 全卸载了会是**空数组**，
        //    那种情况**不能**再塞回默认列表（否则"卸载光了下次又全回来"）。
        if appsByOwner[id] == nil {
            appsByOwner[id] = Self.defaultApps
        }
        apps = appsByOwner[id] ?? []
        events = eventsByOwner[id] ?? []
    }

    func forget(_ id: UUID) {
        appsByOwner[id] = nil
        eventsByOwner[id] = nil
        if owner == id {
            apps = []
            events = []
        }
        save()
    }

    // MARK: - 装 / 卸

    /// ta"装"了一个 App。
    @discardableResult
    func install(name: String, symbol: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let app = HerApp(name: trimmed, symbol: symbol)
        apps.append(app)
        save()
        return app.id
    }

    /// 卸载一个 App。
    func uninstall(id: String) {
        apps.removeAll { $0.id == id }
        save()
    }

    // MARK: - 动作

    /// ta 手机上做了一件事（点某个 App 打开的入口在这）。
    ///
    /// 两件事一起做：
    ///  1. 落一条 `events`（界面上的"最近动态"，滚动裁剪到 `maxEvents`）；
    ///  2. 在**当前会话**里落一条 `.herPhone` 聊天消息 —— 这样"我"这边
    ///     的聊天记录里就会多一句「ta 刚打开了淘宝」，两边看起来是同步的。
    func logEvent(appName: String, action: String) {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let event = HerPhoneEvent(appName: name, action: action)
        events.append(event)
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
        }
        save()

        // ⚠️ 落聊天走 **ChatStore** 的口子（它自己负责插到流式空占位前面）。
        ChatStore.shared.appendIncomingHerPhone(appName: name, action: action)
    }

    /// 最近 n 条动作，**新的在前**（界面直接拿去 forEach）。
    func recentEvents(_ count: Int = 12) -> [HerPhoneEvent] {
        Array(events.suffix(max(0, count)).reversed())
    }

    // MARK: - 存档

    private struct Archive: Codable {
        var apps: [String: [HerApp]] = [:]
        var events: [String: [HerPhoneEvent]] = [:]
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        loading = true
        defer { loading = false }
        appsByOwner = archived.apps.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        eventsByOwner = archived.events.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
    }

    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        appsByOwner[owner] = apps
        eventsByOwner[owner] = events
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    private func writeArchive() {
        guard !appsByOwner.isEmpty || !eventsByOwner.isEmpty else { return }
        let archive = Archive(apps: flatApps(), events: flatEvents())
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func flatApps() -> [String: [HerApp]] {
        appsByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }

    private func flatEvents() -> [String: [HerPhoneEvent]] {
        eventsByOwner.reduce(into: [:]) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
    }
}

// MARK: - 备份与搬家

extension HerPhoneStore: BackupableStore {
    var backupName: String { "herphone" }

    func exportBackup() throws -> Data {
        stash()
        return try JSONEncoder().encode(Archive(apps: flatApps(), events: flatEvents()))
    }

    func importBackup(_ data: Data) throws {
        let archived = try JSONDecoder().decode(Archive.self, from: data)
        loading = true
        defer { loading = false }
        appsByOwner = archived.apps.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        eventsByOwner = archived.events.reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        apps = owner.flatMap { appsByOwner[$0] } ?? []
        events = owner.flatMap { eventsByOwner[$0] } ?? []
        writeArchive()
    }
}
