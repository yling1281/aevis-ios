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

    /// 点开这个 App 之后走哪种"面"。
    ///
    /// `nil` = 还没定 —— 去 `HerAppCatalog.surface(forID:)` 按 id 查默认。
    /// （老存档里没有这个 key，解出来就是 `nil`；store 会在内存里补上。）
    var surface: HerAppSurface? = nil
    /// 语义色名（`"green"` / `"blue"` …）。
    /// `nil` = 保持现在"按名字算色"的老行为（旧的 `HerPhoneStyle.tint(for:)`）。
    var accent: String? = nil
    /// 内置的 App 能不能卸载。
    var isBuiltin: Bool = false
    /// 排序用。`0` = 按现有顺序追加（用户新装进来的）。
    var order: Int = 0

    /// 进存档的 key。和下面的 `init(from:)` 必须一一对应。
    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, installedAt, surface, accent, isBuiltin, order
    }

    init(id: String = UUID().uuidString,
         name: String,
         symbol: String,
         installedAt: Date = Date(),
         surface: HerAppSurface? = nil,
         accent: String? = nil,
         isBuiltin: Bool = false,
         order: Int = 0) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.installedAt = installedAt
        self.surface = surface
        self.accent = accent
        self.isBuiltin = isBuiltin
        self.order = order
    }

    // MARK: - 持久化（🔴 手写解码，改动里最要紧的一处）

    /// 手写 `init(from:)` —— **这是整个改动里最要紧、最容易丢用户数据的地方**。
    ///
    /// 为什么不能靠自动合成：`HerApp` 是 `Codable` 且**已经持久化**过。
    /// 给新字段写 `= nil` 默认值**救不了它** —— 自动合成的 `init(from:)` 遇到
    /// "JSON 里没有这个 key" 会直接抛 `keyNotFound`，整份存档都解不出来。
    /// 所以这里**每个字段**都走 `decodeIfPresent` + 兜底：
    ///   · 老存档里没有的新字段（surface / accent / isBuiltin / order）→ 各自默认值；
    ///   · 残缺/损坏的老字段（缺 id、缺 name…）→ 也绝不抛错，给一个安全兜底。
    ///
    /// `encode(to:)` 故意**不写** —— 让编译器自动合成（用上面那套 `CodingKeys`）。
    /// 只提供 `init(from:)` 不会取消 `encode(to:)` 的合成。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawID = Self.lenient(String.self, .id, from: container, fallback: "")
        self.id = rawID.isEmpty ? UUID().uuidString : rawID

        let rawName = Self.lenient(String.self, .name, from: container, fallback: "")
        self.name = rawName.isEmpty ? "App" : rawName

        let rawSymbol = Self.lenient(String.self, .symbol, from: container, fallback: "")
        self.symbol = rawSymbol.isEmpty ? "app.fill" : rawSymbol

        self.installedAt = Self.lenient(Date.self, .installedAt, from: container, fallback: Date())

        // 可选字段单独写：`(try? decodeIfPresent) ?? nil` 把 `T??` 压成 `T?`，
        // key 不在 / 值为 null / 类型不对 → 都得到 nil。
        self.surface = (try? container.decodeIfPresent(HerAppSurface.self, forKey: .surface)) ?? nil
        self.accent = (try? container.decodeIfPresent(String.self, forKey: .accent)) ?? nil

        self.isBuiltin = Self.lenient(Bool.self, .isBuiltin, from: container, fallback: false)
        self.order = Self.lenient(Int.self, .order, from: container, fallback: 0)
    }

    /// `decodeIfPresent` 的容错版：key 不存在、值为 null、类型不对 —— 一律退回兜底，绝不抛错。
    private static func lenient<T: Decodable>(
        _ type: T.Type,
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>,
        fallback: T
    ) -> T {
        let decoded: T?? = try? container.decodeIfPresent(type, forKey: key)
        return decoded.flatMap { $0 } ?? fallback
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

    /// 存档里记下的**格式版本**（没有这个 key 的老存档 = 0）。见 `migrateIfNeeded()`。
    private var archivedVersion = 0

    /// 当前存档格式版本。
    ///  · `0` / 缺省 = 只有 id/name/symbol/installedAt 的旧格式；
    ///  · `2` = 已把 2026-10-06 新增的三个内置 App（推特 / 百度网盘 / 浏览器）
    ///          并进**已经存在**的 ta 的手机里。
    private static let archiveVersion = 2

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
    /// ⚠️ 现在**统一由 `HerAppCatalog` 产出**（单一事实来源）：名字 / 图标 /
    ///    色名 / 点开走哪种面全在目录里定义，这里只是展开成 `HerApp`。
    ///    好处是新增一个 App 只改目录一处，不用两边同步。
    ///
    /// ⚠️ 每个 `symbol` 都是**系统里真有**的 SF Symbol —— 别随手改。
    static let defaultApps: [HerApp] = HerAppCatalog.defaultApps()

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
        // 老存档里的 App 没有 `surface` —— 在**内存里**按 id 补上默认的"面"。
        // ⚠️ 故意不在这里落盘：补 surface 是派生数据，下次因别的原因 `save()` 时
        //    自然会跟着写回去，不必为它单独整份改写用户数据。
        apps = backfillSurfaces(appsByOwner[id] ?? [])
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
    ///
    /// 名字能对上目录里的内置 App 时，顺手把它的"面"/色名带上 ——
    /// 这样手动装回来的「微信」点开还是聊天列表，而不是兜底页。
    /// 对不上（用户自己编的 App）→ `.generic`（只显示一句"她打开了 X"）。
    @discardableResult
    func install(name: String, symbol: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var app = HerApp(name: trimmed, symbol: symbol)
        if let entry = HerAppCatalog.entry(forName: trimmed) {
            app.surface = entry.surface
            app.accent = entry.accent
        } else {
            app.surface = .generic
        }
        apps.append(app)
        save()
        return app.id
    }

    /// 卸载一个 App。
    func uninstall(id: String) {
        apps.removeAll { $0.id == id }
        save()
    }

    // MARK: - 查询 / 目录

    /// 按 id 取一个 App（供下一轮界面用）。找不到返回 `nil`。
    func app(withID id: String) -> HerApp? {
        apps.first { $0.id == id }
    }

    /// 给 `surface == nil` 的 App 补上默认的"面"（按 id 去目录里查；查不到 → `.generic`）。
    ///
    /// ⚠️ **只在内存里补**，不落盘、不整份改写用户数据 —— 目的就是让老存档也能正常点开。
    ///    已经定过 `surface` 的 App 原样返回，不动它。
    private func backfillSurfaces(_ list: [HerApp]) -> [HerApp] {
        list.map { app in
            guard app.surface == nil else { return app }
            var copy = app
            copy.surface = HerAppCatalog.surface(forID: app.id)
            return copy
        }
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
        /// 存档格式版本。
        /// 🔴 **必须声明成 `Int?`** —— 自动合成的解码器对 **Optional** 字段走
        ///    `decodeIfPresent`，所以**没有这个 key 的旧存档照样解得出来**；
        ///    写成 `var version: Int = 0` 反而会让旧存档直接抛 `keyNotFound`,
        ///    整个"她的手机"数据全丢。
        var version: Int? = nil
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
        archivedVersion = archived.version ?? 0
        // 🔴 这一步不能省：老存档里的手机只有旧那 12 个 App，
        //    不迁移的话老板升级完**看不到**推特 / 百度网盘 / 浏览器。
        if migrateIfNeeded() { writeArchive() }
    }

    // MARK: - 迁移

    /// 一次性把**后来新增的内置 App** 补进"已经有手机"的联系人里。
    ///
    /// 🔴 为什么必须有这一段（2026-10-06 踩过）：
    ///    `setOwner` 只在 `appsByOwner[id] == nil`（这个人**从来没建过手机**）时才
    ///    用 `defaultApps` 装那套默认 App。老用户手机上早就有 12 个 App 了 ⇒
    ///    永远走不到那一步 ⇒ **只改目录/`defaultApps` 是完全没用的**，
    ///    升级完仍然是老样子。所以必须在**读档**这一刻做一次合并。
    ///
    /// ⚠️ 只在 `archivedVersion < archiveVersion` 时跑一次（跑完把版本落盘）——
    ///    这样用户**之后自己卸载**掉的 App 不会在下次启动又冒出来。
    /// ⚠️ **空列表跳过**（用户把 App 全卸载光了）—— 尊重那个状态，别硬塞回来。
    /// ⚠️ 返回值 = 有没有改到数据；调用方据此决定要不要落盘。
    @discardableResult
    private func migrateIfNeeded() -> Bool {
        guard archivedVersion < Self.archiveVersion else { return false }

        let builtins = HerAppCatalog.defaultApps()
        for (id, list) in appsByOwner where !list.isEmpty {
            var merged = list
            // 老存档里 `order` 全是 0 —— 先按当前数组顺序把序号钉住，
            // 否则新补进来的 App 会和老的撞同一个序号，界面排序就乱了。
            if merged.allSatisfy({ $0.order == 0 }) {
                for index in merged.indices { merged[index].order = index + 1 }
            }
            let existing = Set(merged.map { $0.id })
            for app in builtins where !existing.contains(app.id) {
                merged.append(app)
            }
            appsByOwner[id] = merged
        }

        archivedVersion = Self.archiveVersion
        return true
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
        let archive = Archive(apps: flatApps(), events: flatEvents(),
                              version: Self.archiveVersion)
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
        return try JSONEncoder().encode(
            Archive(apps: flatApps(), events: flatEvents(), version: Self.archiveVersion))
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
        // 从老版本搬过来的存档同样要补新 App —— 跟 `load()` 走同一条迁移。
        archivedVersion = archived.version ?? 0
        _ = migrateIfNeeded()
        apps = backfillSurfaces(owner.flatMap { appsByOwner[$0] } ?? [])
        events = owner.flatMap { eventsByOwner[$0] } ?? []
        writeArchive()
    }
}
