import Foundation
import SwiftUI

/// 「钱包」—— **纯本地的假数据**，不接任何真支付。
///
/// ## 用户要的（2026-09-29 原话）
/// 「你弄个假支付功能，就是你这里有钱包，对面那里也有钱包，知道吗？」
/// 「然后支付功能的话，也是气泡。」
///
/// ## ⭐ 2026-10-01：让「ta真的给我打钱」成立 + 加流水
/// 用户原话：「**银行卡：能让 AI 真的给内置的虚拟银行卡打钱。**」
///
/// 查下来这里是个洞：`receive()`（ta给我转）**早就写好了、却一个调用方都没有**；
/// `ChatStore.appendIncomingTransfer`（ta的转账气泡）**同样是死代码**。
/// 也就是说 —— 「ta给我打钱」这条路**以前根本不存在**，聊天里也从来不会出现
/// ta发的转账气泡。这次由 `WalletTools` 把那条路接起来，
/// 并补一张**流水**（`entries`）：**每一次我的余额变动都留痕**。
///
/// ## 钱的闭环（自洽，没有凭空印钞）
/// 我转给ta → ta收下 → **ta的余额真的变多** → ta就能再转回给我。
/// ta转给我时**ta会不够**（`receive` 会拒绝）—— 不是 bug，是设计：
/// ta没钱了就该说没钱，而不是无限给你打钱。
///
/// ⚠️ **别拿它接真钱**。要接真的那套（支付宝 12 元收款）在服务端，
///    跟这个钱包是**两条完全不相干的线** —— 混在一起会出事。
/// 亲密付 / 代付的**方向**。
///
/// - `.mine`：挂在**我的余额**（`myBalance` = 用户/老板的钱包）上 —— **用户出钱**。
/// - `.ta`  ：挂在 **ta 的余额**（`taBalance` = 我的钱包）上 —— **我出钱**。
///
/// ⚠️ 用同一个 enum 收口，避免"两个方向各写一套函数"写歪。
enum ClosePayDirection { case mine, ta }

// MARK: - 「按联系人分存」要用的键（放**文件级**，不放类里）
//
// ⚠️ 为什么不放 `WalletStore` 里：这个类是 `@MainActor` 的，静态成员默认也吃
//    主 actor 隔离；而 `BackupableStore.exportBackup()/importBackup()` 是
//    **nonisolated** 的，要在任意线程上直接读写 UserDefaults —— 常量搬到文件级
//    就不用到处打 `nonisolated` 补丁了（值都是 Sendable 的 String）。

/// 某个联系人钱包 blob 的键前缀。用 `.v2.` 把新结构跟老扁平键**彻底隔开** ——
/// 老键（`aevis.wallet.mine` 那种）一个不动，只在第一次认人时读一次做迁移。
private let walletBlobPrefix = "aevis.wallet.v2."

/// 某个联系人的钱包 blob 键。
private func walletBlobKey(_ id: UUID) -> String {
    walletBlobPrefix + id.uuidString
}

/// 老扁平键迁移过没有。认过一次就落盘置位，免得每切一次人搬一遍。
private let walletLegacyMigratedKey = "aevis.wallet.v2.legacyMigrated"

@MainActor
final class WalletStore: ObservableObject {

    static let shared = WalletStore()

    /// 我钱包里的一笔流水。
    ///
    /// `delta` 是**对我余额**的增减（正=进账、负=出账）——
    /// 显示的时候直接看它，不用再推方向，也就不会出现"符号和文字说的不一样"。
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var date: Date = Date()
        /// 正=进账，负=出账。永远是这一步**实际动了多少**。
        var delta: Double
        /// 人话说明，直接显示。
        var note: String
        /// 这笔钱的来源标签（"每日发放" / "工资" / "亲密付" / "代付" / "转账" …）。
        ///
        /// ⚠️ **必须带默认值 `= nil`**：老流水的 JSON 里根本没有这个键，
        ///    带了默认值 + 是可选项，才能"缺键 → nil"地解出来；不带的话
        ///    老用户那串流水会整条解码失败、当场全空（外面那个 `try?` 会把它悄悄吞掉）。
        var source: String? = nil
        /// 这笔钱动的是**哪一侧**的余额："me"（我的）/ "her"（ta的）/ "shared"（共享金库）。
        /// 老流水没有这个键 → nil，一律当"我的"处理。同样必须带默认值。
        var side: String? = nil
    }

    /// 我的余额。默认给个数，别让人一开始看到 0 觉得是坏的。
    @Published var myBalance: Double {
        didSet { persist() }
    }

    /// ta 的余额。ta也有钱包（用户明确要的）。
    @Published var taBalance: Double {
        didSet { persist() }
    }

    /// 流水，**新的在前**。只由 `record()` 改。
    @Published private(set) var entries: [Entry] = []

    // MARK: - 虚拟银行（每日发放）的设置
    //
    // ⭐ 语义（2026-10-05 定稿，写清免得日后读歪）：
    //   · bankTarget = "her" / "me"：每日那笔进**对应一侧**的卡（默认 "her" = ta的卡）。
    //   · bankTarget = "both"      ：**两张卡各发一整份** —— `bankAmount` 是「每一侧各一份」，
    //                                **不是**把一份对半分给两边；会记两条流水。
    //   · bankShared = true        ：**覆盖上面的 target**，那笔进**家庭共享金库**
    //                                （`sharedBalance`），两侧的卡都不动。

    /// 每日发放总开关。
    @Published var bankEnabled: Bool {
        didSet { persist() }
    }

    /// 每天发多少钱。
    @Published var bankAmount: Double {
        didSet { persist() }
    }

    /// 发到哪一侧："her"（ta的卡）/ "me"（我的卡）/ "both"（两张卡都发）。
    @Published var bankTarget: String {
        didSet { persist() }
    }

    /// 最后一次发放是哪天（本地日期 `yyyy-MM-dd`）。空串 = 从来没发过。
    @Published private(set) var bankLastDay: String = "" {
        didSet { persist() }
    }

    /// 家庭共享：打开后每日发放进**共享金库**，不单独进谁的卡。
    @Published var bankShared: Bool {
        didSet { persist() }
    }

    /// 家庭共享金库的余额。
    @Published var sharedBalance: Double {
        didSet { persist() }
    }

    // MARK: - 亲密付的设置（两个方向各自独立）
    //
    // ⭐ 2026-10-05：亲密付是**双向**的 —— 老板「他也可以给我代付，开亲密付」。
    //    · mine：我给ta开（ta花、**我**付） → 扣 `myBalance`
    //    · ta  ：ta给我开（我花、**ta**付） → 扣 `taBalance`

    /// 我给ta开的亲密付。
    @Published var closePayMineEnabled: Bool {
        didSet { persist() }
    }
    @Published var closePayMineLimit: Double {
        didSet { persist() }
    }
    @Published var closePayMinePeriod: String {
        didSet { persist() }
    }
    @Published var closePayMineUsed: Double {
        didSet { persist() }
    }
    private var closePayMineSince: Double = 0 {
        didSet { persist() }
    }

    /// ta给我开的亲密付（ta主动给的；用户能关掉）。
    @Published var closePayTaEnabled: Bool {
        didSet { persist() }
    }
    @Published var closePayTaLimit: Double {
        didSet { persist() }
    }
    @Published var closePayTaPeriod: String {
        didSet { persist() }
    }
    @Published var closePayTaUsed: Double {
        didSet { persist() }
    }
    private var closePayTaSince: Double = 0 {
        didSet { persist() }
    }

    /// 每日发放的轮询定时器。**挂在 WalletStore 自己内部**（不碰 App/ 目录）。
    private var dailyTimer: Timer?

    // MARK: - 按联系人分存（2026-10）

    /// 现在这份钱包属于谁（联系人 id）。
    private var owner: UUID?
    /// 切人装载 / 搬家导入期间**只读不写**（漏了就是"搬家搬丢"，老 bug）。
    private var loading = false

    /// 一个联系人的**整份钱包**。存 UserDefaults 的 blob、进备份，都走它。
    /// 老版本是 20 多枚扁平键（`aevis.wallet.mine` 那种），现在一个人一份。
    struct OwnerData: Codable {
        var mine: Double = 520.00
        var theirs: Double = 1314.00
        var entries: [Entry] = []
        var bankEnabled: Bool = true
        var bankAmount: Double = 88.00
        var bankTarget: String = "her"
        var bankLastDay: String = ""
        var bankShared: Bool = false
        var bankSharedBalance: Double = 0
        var closePayMineEnabled: Bool = false
        var closePayMineLimit: Double = 2000.00
        var closePayMinePeriod: String = "month"
        var closePayMineUsed: Double = 0
        var closePayMineSince: Double = 0
        var closePayTaEnabled: Bool = false
        var closePayTaLimit: Double = 2000.00
        var closePayTaPeriod: String = "month"
        var closePayTaUsed: Double = 0
        var closePayTaSince: Double = 0
    }

    private enum Key {
        static let mine = "aevis.wallet.mine"
        static let theirs = "aevis.wallet.theirs"
        static let entries = "aevis.wallet.entries"

        // ⚠️ 下面全是 2026-10-05 新增的键 —— 老键一个都没动。
        // 虚拟银行（每日发放）
        static let bankEnabled = "aevis.bank.enabled"
        static let bankAmount = "aevis.bank.amount"
        static let bankTarget = "aevis.bank.target"
        static let bankLastDay = "aevis.bank.lastDay"
        static let bankShared = "aevis.bank.shared"
        static let bankSharedBalance = "aevis.bank.sharedBalance"
        // 亲密付（双向，各自独立）
        static let closePayMineEnabled = "aevis.wallet.closepay.mine.enabled"
        static let closePayMineLimit = "aevis.wallet.closepay.mine.limit"
        static let closePayMinePeriod = "aevis.wallet.closepay.mine.period"
        static let closePayMineUsed = "aevis.wallet.closepay.mine.used"
        static let closePayMineSince = "aevis.wallet.closepay.mine.since"
        static let closePayTaEnabled = "aevis.wallet.closepay.ta.enabled"
        static let closePayTaLimit = "aevis.wallet.closepay.ta.limit"
        static let closePayTaPeriod = "aevis.wallet.closepay.ta.period"
        static let closePayTaUsed = "aevis.wallet.closepay.ta.used"
        static let closePayTaSince = "aevis.wallet.closepay.ta.since"
    }

    /// 流水最多留多少条。再多也没人翻，而且这是 UserDefaults。
    private static let maxEntries = 200

    /// 转账常用金额（微信那排快捷数字）+ 一个红包的吉利数。
    static let quickAmounts: [Double] = [5.20, 13.14, 52.00, 88.88, 200.00]

    private init() {
        // 只铺默认值 —— 真正的钱在 `setOwner` 里按联系人装载（见 `applyOwner`）。
        // 老版本那 20 多枚扁平键的迁移也在那一步**一次性**做掉。
        //
        // ⚠️ 这里**别**再读扁平键、也**别**调 `grantDailyIfNeeded()`：
        //    此刻还没有 owner（`owner == nil`），`persist()` 会直接返回，
        //    发了也存不下来（等于白发）。每日发放改到 `applyOwner` 里补。
        myBalance = 520.00
        taBalance = 1314.00
        bankEnabled = true
        bankAmount = 88.00
        bankTarget = "her"
        bankLastDay = ""
        bankShared = false
        sharedBalance = 0
        closePayMineEnabled = false
        closePayMineLimit = 2000.00
        closePayMinePeriod = "month"
        closePayMineUsed = 0
        closePayMineSince = 0
        closePayTaEnabled = false
        closePayTaLimit = 2000.00
        closePayTaPeriod = "month"
        closePayTaUsed = 0
        closePayTaSince = 0

        BlackBox.log("钱包：初始化（等第一个联系人进来再装载）")

        // ⭐ 每日发放：之后每 60 秒查一次。定时器挂在 WalletStore 自己内部，
        //    **绝不碰 App/ 目录**（那边别人在同时改）。
        //    启动时那一次补发由 `applyOwner` 负责（要有 owner 才发得出去）。
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.grantDailyIfNeeded() }
        }
    }

    // MARK: - 切人 / 存档（按联系人分存，2026-10）

    /// 切到某个联系人。`PersonaStore.broadcastSwitch` 切人时来调它。
    ///
    /// ⚠️ `WalletStore` 整个类是 `@MainActor`，而调用点
    ///    （`PersonaStore.broadcastSwitch` / `remove`）是**非隔离**的 ——
    ///    直接声明成 `@MainActor` 会编译不过。所以这里标 `nonisolated`，
    ///    内部自己判断要不要跳主线程：已经在主线程就 `assumeIsolated` **就地**
    ///    跑（切人是同步语义，界面得立刻换过来），万一是别的线程就甩回主 actor。
    nonisolated func setOwner(_ id: UUID?) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.applyOwner(id) }
        } else {
            Task { @MainActor in self.applyOwner(id) }
        }
    }

    /// 删联系人时把某个人的整份钱包扔掉。
    nonisolated func forget(_ id: UUID) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.applyForget(id) }
        } else {
            Task { @MainActor in self.applyForget(id) }
        }
    }

    @MainActor
    private func applyOwner(_ id: UUID?) {
        // 切人前先把当前这份写回字典，免得丢改动。
        stash()
        owner = id

        guard let id else {
            // 一个联系人都没有 —— 给一份默认的，别让界面看着像坏的。
            applyData(OwnerData())
            return
        }

        // 先看内存缓存，再看落盘的 blob。
        var data = byOwner[id] ?? Self.readBlob(id)

        // 老版本（单人）那 20 多枚扁平键 → 认给**第一个进来的人**。
        // 只认一次（`walletLegacyMigratedKey` 落盘记住），免得每切一次人搬一遍、
        // 把别人后来改的数据又盖回老的。
        if data == nil, !UserDefaults.standard.bool(forKey: walletLegacyMigratedKey) {
            data = Self.legacyData()
            UserDefaults.standard.set(true, forKey: walletLegacyMigratedKey)
        }

        let resolved = data ?? OwnerData()
        byOwner[id] = resolved
        applyData(resolved)

        // ⭐ 启动 / 切人后补一次每日发放（原来在 `init` 里做，那时还没有 owner）。
        //    `grantDailyIfNeeded` 内部有 `bankLastDay` 把关 —— 同一个联系人一天只发一次。
        grantDailyIfNeeded()
    }

    @MainActor
    private func applyForget(_ id: UUID) {
        byOwner[id] = nil
        UserDefaults.standard.removeObject(forKey: walletBlobKey(id))
        if owner == id {
            owner = nil
            applyData(OwnerData())
        }
    }

    /// 把当前 `@Published` 那份收进内存字典（**不落盘**）。
    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        byOwner[owner] = captureData()
    }

    /// 任何一处 `@Published` 改动都从这里落盘 —— 取代老版本"每枚扁平键各写各的"。
    ///
    /// 🔴 写的一定是**当前 owner**：`captureData()` 抓的就是界面上这份，
    ///    而 `owner` 只可能被 `applyOwner`（同一个主 actor）改 —— 两者永远同步。
    ///    `dailyTimer` 后台触发时跑的 `grantDailyIfNeeded()` 改的也是这几个
    ///    `@Published`，于是它落盘的方向自然也是**当前联系人**，不会写到别人账上。
    private func persist() {
        guard !loading else { return }
        guard let owner else { return }
        let data = captureData()
        byOwner[owner] = data
        Self.writeBlob(owner, data)
    }

    /// 当前这份钱包（界面状态）打包成一份 `OwnerData`。
    private func captureData() -> OwnerData {
        var data = OwnerData()
        data.mine = myBalance
        data.theirs = taBalance
        data.entries = entries
        data.bankEnabled = bankEnabled
        data.bankAmount = bankAmount
        data.bankTarget = bankTarget
        data.bankLastDay = bankLastDay
        data.bankShared = bankShared
        data.bankSharedBalance = sharedBalance
        data.closePayMineEnabled = closePayMineEnabled
        data.closePayMineLimit = closePayMineLimit
        data.closePayMinePeriod = closePayMinePeriod
        data.closePayMineUsed = closePayMineUsed
        data.closePayMineSince = closePayMineSince
        data.closePayTaEnabled = closePayTaEnabled
        data.closePayTaLimit = closePayTaLimit
        data.closePayTaPeriod = closePayTaPeriod
        data.closePayTaUsed = closePayTaUsed
        data.closePayTaSince = closePayTaSince
        return data
    }

    /// 一份 `OwnerData` 铺到界面状态。**全程 `loading` 挡写** —— 否则下面每一次
    /// 赋值都会触发 `didSet → persist()`，把刚载入的又写回磁盘（搬家场景会出事）。
    private func applyData(_ data: OwnerData) {
        loading = true
        defer { loading = false }
        myBalance = data.mine
        taBalance = data.theirs
        entries = data.entries
        bankEnabled = data.bankEnabled
        bankAmount = data.bankAmount
        bankTarget = data.bankTarget
        bankLastDay = data.bankLastDay
        bankShared = data.bankShared
        sharedBalance = data.bankSharedBalance
        closePayMineEnabled = data.closePayMineEnabled
        closePayMineLimit = data.closePayMineLimit
        closePayMinePeriod = data.closePayMinePeriod
        closePayMineUsed = data.closePayMineUsed
        closePayMineSince = data.closePayMineSince
        closePayTaEnabled = data.closePayTaEnabled
        closePayTaLimit = data.closePayTaLimit
        closePayTaPeriod = data.closePayTaPeriod
        closePayTaUsed = data.closePayTaUsed
        closePayTaSince = data.closePayTaSince
    }

    /// 老版本那 20 多枚扁平键 → 一份 `OwnerData`（**只读，不动老键**）。
    /// 只用来做一次性迁移；读不出来的项一律退回 `OwnerData` 的默认值。
    private static func legacyData() -> OwnerData {
        let defaults = UserDefaults.standard
        var data = OwnerData()
        data.mine = defaults.object(forKey: Key.mine) as? Double ?? data.mine
        data.theirs = defaults.object(forKey: Key.theirs) as? Double ?? data.theirs
        if let raw = defaults.data(forKey: Key.entries),
           let list = try? JSONDecoder().decode([Entry].self, from: raw) {
            data.entries = list
        }
        data.bankEnabled = defaults.object(forKey: Key.bankEnabled) as? Bool ?? data.bankEnabled
        data.bankAmount = defaults.object(forKey: Key.bankAmount) as? Double ?? data.bankAmount
        let target = defaults.string(forKey: Key.bankTarget) ?? data.bankTarget
        data.bankTarget = (target == "me" || target == "both") ? target : "her"
        data.bankLastDay = defaults.string(forKey: Key.bankLastDay) ?? data.bankLastDay
        data.bankShared = defaults.object(forKey: Key.bankShared) as? Bool ?? data.bankShared
        data.bankSharedBalance =
            defaults.object(forKey: Key.bankSharedBalance) as? Double ?? data.bankSharedBalance
        data.closePayMineEnabled =
            defaults.object(forKey: Key.closePayMineEnabled) as? Bool ?? data.closePayMineEnabled
        data.closePayMineLimit =
            defaults.object(forKey: Key.closePayMineLimit) as? Double ?? data.closePayMineLimit
        let minePeriod = defaults.string(forKey: Key.closePayMinePeriod) ?? data.closePayMinePeriod
        data.closePayMinePeriod = (minePeriod == "day") ? "day" : "month"
        data.closePayMineUsed =
            defaults.object(forKey: Key.closePayMineUsed) as? Double ?? data.closePayMineUsed
        data.closePayMineSince =
            defaults.object(forKey: Key.closePayMineSince) as? Double ?? data.closePayMineSince
        data.closePayTaEnabled =
            defaults.object(forKey: Key.closePayTaEnabled) as? Bool ?? data.closePayTaEnabled
        data.closePayTaLimit =
            defaults.object(forKey: Key.closePayTaLimit) as? Double ?? data.closePayTaLimit
        let taPeriod = defaults.string(forKey: Key.closePayTaPeriod) ?? data.closePayTaPeriod
        data.closePayTaPeriod = (taPeriod == "day") ? "day" : "month"
        data.closePayTaUsed =
            defaults.object(forKey: Key.closePayTaUsed) as? Double ?? data.closePayTaUsed
        data.closePayTaSince =
            defaults.object(forKey: Key.closePayTaSince) as? Double ?? data.closePayTaSince
        return data
    }

    /// 读某个联系人落盘的 blob。
    private nonisolated static func readBlob(_ id: UUID) -> OwnerData? {
        guard let raw = UserDefaults.standard.data(forKey: walletBlobKey(id)) else { return nil }
        return try? JSONDecoder().decode(OwnerData.self, from: raw)
    }

    /// 写某个联系人落盘的 blob。
    private nonisolated static func writeBlob(_ id: UUID, _ data: OwnerData) {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(raw, forKey: walletBlobKey(id))
    }

    /// 本机**现存的**所有联系人钱包 blob 键（按 `walletBlobPrefix` + 合法 uuid 认）。
    /// ⚠️ `walletLegacyMigratedKey` 虽然也带前缀，但后缀不是 uuid ⇒ 认不出来、会被跳过。
    private nonisolated static func existingBlobKeys() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix(walletBlobPrefix) else { return false }
            let suffix = String(key.dropFirst(walletBlobPrefix.count))
            return UUID(uuidString: suffix) != nil
        }
    }

    // MARK: - 流水

    /// 记一笔。**这是唯一会动 `entries` 的地方** —— 别处别直接改。
    ///
    /// 金额先夹成两位小数再判零：`0.001` 这种"转了但账上没变"的必须挡掉，
    /// 否则流水里会出现一行 ¥0.00，看着像坏的。
    private func record(_ delta: Double, note: String,
                        source: String? = nil, side: String? = nil) {
        let value = (delta * 100).rounded() / 100
        guard value != 0 else { return }
        var list = entries
        list.insert(Entry(delta: value, note: note, source: source, side: side), at: 0)
        if list.count > Self.maxEntries {
            list.removeLast(list.count - Self.maxEntries)
        }
        entries = list
        persist()
        BlackBox.log("钱包流水：\(value > 0 ? "+" : "")\(String(format: "%.2f", value)) \(note)")
    }

    /// 这一笔对余额来说是进账还是出账。
    static func isIncome(_ entry: Entry) -> Bool { entry.delta > 0 }

    /// 流水里那个金额怎么显示：带正负号。
    static func signedMoney(_ value: Double) -> String {
        String(format: "%@¥%.2f", value > 0 ? "+" : "-", abs(value))
    }

    /// 流水里那行时间。今天的只显示时分，别的显示月-日。
    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd"
        return formatter.string(from: date)
    }

    // MARK: - 虚拟银行 · 每日发放

    /// 今天的本地日期键（`yyyy-MM-dd`）。用**本地日历**算，跨时区/夏令时都对。
    private static func todayKey(_ date: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// 今天是不是已经发过了 —— 给界面显示「今天已经发过啦 / 还没发」。
    var didGrantToday: Bool { bankLastDay == Self.todayKey() }

    /// 每日发放发到哪（给界面显示用的人话）。
    var bankTargetLabel: String {
        switch bankTarget {
        case "me": return "我的卡"
        case "both": return "两张卡都发"
        default: return "\(Pronoun.current)的卡"
        }
    }

    /// 每日发放。启动时调一次，之后每 60 秒由 `dailyTimer` 调一次。
    ///
    /// 用本地日历算今天；`bankLastDay` 不等于今天就认为"这个周期还没发"。
    /// 顺序很重要：**通过全部校验、改完余额、记完流水，最后才写 `bankLastDay`**——
    /// 反过来的话中途 return 会让"没发成"被误标成"已发"。
    @discardableResult
    func grantDailyIfNeeded() -> Bool {
        guard bankEnabled else { return false }
        let today = Self.todayKey()
        guard bankLastDay != today else { return false }

        let value = (bankAmount * 100).rounded() / 100
        guard value > 0 else { return false }

        if bankShared {
            // 家庭共享：进共享金库，不单独进谁的卡。
            sharedBalance += value
            record(value, note: "每日发放（家庭共享）", source: "每日发放", side: "shared")
        } else {
            switch bankTarget {
            case "me":
                myBalance += value
                record(value, note: "每日发放", source: "每日发放", side: "me")
            case "both":
                // 两边各发一份 —— 金额是"每一侧各一份"，不是对半分。
                myBalance += value
                taBalance += value
                record(value, note: "每日发放（打到我的卡）", source: "每日发放", side: "me")
                record(value, note: "每日发放（打到\(Pronoun.current)的卡）", source: "每日发放", side: "her")
            default:
                taBalance += value
                record(value, note: "每日发放（打到\(Pronoun.current)的卡）", source: "每日发放", side: "her")
            }
        }

        bankLastDay = today
        BlackBox.log("虚拟银行：每日发放 \(Self.money(value))"
                     + " · target=\(bankTarget) · shared=\(bankShared)")
        return true
    }

    // MARK: - 亲密付

    /// 开通 / 改额度（**按方向**）。会重置该方向的"本期已用"为 0，并把起点设成现在。
    func openClosePay(_ dir: ClosePayDirection, limit: Double, period: String) {
        let value = (limit * 100).rounded() / 100
        guard value > 0 else { return }
        let cycle = (period == "day") ? "day" : "month"
        let now = Date().timeIntervalSince1970
        switch dir {
        case .mine:
            closePayMineEnabled = true
            closePayMineLimit = value
            closePayMinePeriod = cycle
            closePayMineUsed = 0
            closePayMineSince = now
        case .ta:
            closePayTaEnabled = true
            closePayTaLimit = value
            closePayTaPeriod = cycle
            closePayTaUsed = 0
            closePayTaSince = now
        }
    }

    /// 关掉某一个方向的亲密付。**不清 used** —— 历史留着，下次开通也从 0 起算。
    func closeClosePay(_ dir: ClosePayDirection) {
        switch dir {
        case .mine: closePayMineEnabled = false
        case .ta: closePayTaEnabled = false
        }
    }

    /// 周期翻篇就把该方向的"本期已用"清零 —— **两个方向都检查**。
    ///
    /// ⚠️ 翻篇时**顺带把"本期起点"挪到现在**。不挪的话起点会永远停在开通那天，
    ///    之后每次消费都再清一遍 → 本期用量永远攒不起来（真会踩）。
    func resetClosePayPeriodIfNeeded() {
        let now = Date()
        let calendar = Calendar.current
        if closePayMineSince > 0 {
            let since = Date(timeIntervalSince1970: closePayMineSince)
            if Self.periodRolled(from: since, period: closePayMinePeriod, now: now, calendar: calendar) {
                closePayMineUsed = 0
                closePayMineSince = now.timeIntervalSince1970
            }
        }
        if closePayTaSince > 0 {
            let since = Date(timeIntervalSince1970: closePayTaSince)
            if Self.periodRolled(from: since, period: closePayTaPeriod, now: now, calendar: calendar) {
                closePayTaUsed = 0
                closePayTaSince = now.timeIntervalSince1970
            }
        }
    }

    /// 周期有没有翻篇：日看"期初是不是今天"，月看 month/year 变没变。
    private static func periodRolled(from since: Date, period: String,
                                     now: Date, calendar: Calendar) -> Bool {
        if period == "day" {
            return !calendar.isDateInToday(since)
        }
        return !calendar.isDate(since, equalTo: now, toGranularity: .month)
    }

    /// 一次**亲密付消费**（按方向）。
    /// - `.mine`（用户给"我"开的）：从**我的余额**（`myBalance`）扣；
    /// - `.ta`  （"我"给用户开的）：从 **ta 的余额**（`taBalance`）扣。
    ///
    /// ⚠️ 该方向的 开关 / 额度 / **付款方余额**，任一不过就返回 `0` ——
    ///    **调用方必须照实说"没付成"，不许假装成功**。
    /// ⚠️ 不复用 `receive()`（那是"ta给我钱"，方向完全不同）。
    @discardableResult
    func closePaySpend(_ dir: ClosePayDirection, amount: Double, reason: String) -> Double {
        resetClosePayPeriodIfNeeded()
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return 0 }

        switch dir {
        case .mine:
            guard closePayMineEnabled else { return 0 }
            // 浮点比较留一点余量，免得正好卡在额度上被误判超支。
            guard closePayMineUsed + value <= closePayMineLimit + 0.001 else { return 0 }
            guard value <= myBalance else { return 0 }
            myBalance -= value
            closePayMineUsed += value
            record(-value, note: Self.prefixed("亲密付", reason), source: "亲密付", side: "me")
        case .ta:
            guard closePayTaEnabled else { return 0 }
            guard closePayTaUsed + value <= closePayTaLimit + 0.001 else { return 0 }
            guard value <= taBalance else { return 0 }
            taBalance -= value
            closePayTaUsed += value
            record(-value, note: Self.prefixed("ta 开的亲密付", reason),
                   source: "亲密付", side: "her")
        }
        return value
    }

    /// 一次**代付**（双向）。一次性，不占亲密付额度，只看付款方余额。
    /// - `.mine`：用户掏钱（扣 `myBalance`）；
    /// - `.ta`  ："我"掏钱（扣 `taBalance`）。
    ///   🔴 `.ta` 必须校验"我够不够" —— 不够就返回 `0`，**绝不许凭空给自己加钱**。
    @discardableResult
    func proxyPay(_ dir: ClosePayDirection, amount: Double, reason: String) -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return 0 }

        switch dir {
        case .mine:
            guard value <= myBalance else { return 0 }
            myBalance -= value
            record(-value, note: Self.prefixed("代付", reason), source: "代付", side: "me")
        case .ta:
            guard value <= taBalance else { return 0 }
            taBalance -= value
            record(-value, note: Self.prefixed("ta 代付", reason), source: "代付", side: "her")
        }
        return value
    }

    /// 用户**自己掏钱**（不走亲密付、不走代付）—— 比如「真实生活」里选了「我自己付」。
    ///
    /// ⚠️ **故意不复用 `send`**：`send` 的流水文案写死的是「转给 ta」——
    ///    用在买东西上，账单会多出一行「转给 ta ¥199」，一笔购物看起来像一笔转账，
    ///    跟订单里那句「我自己付」当场自相矛盾。扣钱的动作一样、**语义不一样**，
    ///    所以单独开一个，让流水的 note / source 说得对（`source` 由调用方给，
    ///    购物传「购物」、外卖传「外卖」）。
    /// ⚠️ 余额不够返回 `0` —— 调用方必须照实说"没付成"，不许假装成功。
    @discardableResult
    func spendAsMe(amount: Double, reason: String, source: String = "消费") -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0, value <= myBalance else { return 0 }
        myBalance -= value
        record(-value, note: Self.prefixed(source, reason), source: source, side: "me")
        return value
    }

    /// 「我自己付」这笔付得起吗 —— **只读**预检，给界面判断这个方式能不能选。
    ///
    /// ⚠️ 判据必须与 `spendAsMe` **逐字一致**（金额先夹两位小数，再看余额够不够），
    ///    否则会出现"界面说能选、点下去却返回 0"的自相矛盾。
    func canSpendAsMe(_ amount: Double) -> Bool {
        let value = (amount * 100).rounded() / 100
        return value > 0 && value <= myBalance
    }

    /// 「亲密付」这个方向现在能用吗 —— **只读**预检。
    ///
    /// 判据与 `closePaySpend(_:amount:reason:)` **逐字一致**：开没开 + 本期额度够不够
    /// （额度那一步留 `+ 0.001` 余量，同 `closePaySpend`）+ 付款方余额够不够。
    ///
    /// 🔴 必须先 `resetClosePayPeriodIfNeeded()`：跨天 / 跨月后"本期已用"要清零。
    ///    不先翻篇的话，判据会拿**上一期的用量**去卡这一期的单 —— 明明额度空着却说不够。
    func canClosePay(_ dir: ClosePayDirection, amount: Double) -> Bool {
        resetClosePayPeriodIfNeeded()
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return false }
        switch dir {
        case .mine:
            guard closePayMineEnabled else { return false }
            guard closePayMineUsed + value <= closePayMineLimit + 0.001 else { return false }
            return value <= myBalance
        case .ta:
            guard closePayTaEnabled else { return false }
            guard closePayTaUsed + value <= closePayTaLimit + 0.001 else { return false }
            return value <= taBalance
        }
    }

    /// 「代付」这个方向现在能用吗 —— **只读**预检。
    ///
    /// 代付是一锤子买卖、**不占**亲密付额度，所以判据与 `proxyPay(_:amount:reason:)`
    /// 一样**只看付款方余额**。
    func canProxyPay(_ dir: ClosePayDirection, amount: Double) -> Bool {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return false }
        switch dir {
        case .mine: return value <= myBalance
        case .ta: return value <= taBalance
        }
    }

    /// ta**工作挣到的钱** —— 加进**ta的余额**，流水记一笔"工资"。
    ///
    /// 跟 `receive`（ta给我钱）不是一回事：这是**ta自己的收入**，我的余额一分不动。
    @discardableResult
    func earnAsHer(amount: Double, note: String) -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return 0 }
        taBalance += value
        record(value, note: note.isEmpty ? "工资" : note, source: "工资", side: "her")
        return value
    }

    /// "前缀：正文"；正文为空就只留前缀。
    private static func prefixed(_ prefix: String, _ body: String) -> String {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? prefix : "\(prefix)：\(text)"
    }

    // MARK: - 转账

    /// 我转给ta。返回**实际转出去的金额**（钱不够就转不出来，回 0）。
    ///
    /// ⚠️ 真的会做余额校验 —— 假钱包也要自洽，不然余额变成负数就成了笑话。
    /// ⭐ #23（2026-09-30）：这里**只扣我的钱**，ta 的钱等「ta收下」那一刻才加
    ///    （见 `acceptIncoming`）；ta不肯收就 `refund` 退回。
    @discardableResult
    func send(amount: Double, note: String = "") -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0, value <= myBalance else { return 0 }
        myBalance -= value
        record(-value, note: note.isEmpty ? "转给 ta（等\(Pronoun.current)收）" : "转给 ta：\(note)")
        return value
    }

    /// ta收下我转过去的钱 → 加进ta的余额。
    ///
    /// **不记流水** —— 流水是「我的收支」，这一步没动我一分钱。
    /// ta收没收，聊天里那条气泡自己会变成「已收款」。
    func acceptIncoming(_ amount: Double) {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        taBalance += value
    }

    /// ta不肯收 → 钱退回我的余额。
    func refund(_ amount: Double, note: String = "") {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        myBalance += value
        record(value, note: note.isEmpty ? "ta 没肯收，退回" : note)
    }

    /// ta转给我（ta主动给的那种）。
    ///
    /// ⚠️ **2026-10-01 加了「ta够不够」的校验**。老写法是
    ///    `taBalance = max(0, taBalance - value)` 然后照加我的 ——
    ///    也就是**ta没钱也能给你**，那等于凭空印钞，多转几次ta的钱包就废了。
    ///    现在不够就返回 `0`，**调用方要照实把这件事说出来**（别假装成功）。
    @discardableResult
    func receive(amount: Double, note: String = "") -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0, value <= taBalance else { return 0 }
        taBalance -= value
        myBalance += value
        record(value, note: note.isEmpty ? "ta 转给我" : "ta 转给我：\(note)")
        return value
    }

    /// 重置成默认（设置里给个「恢复默认」用得上，也方便演示）。
    /// 流水也一起清掉 —— 余额都回到出厂了，留着旧账单只会对不上。
    func reset() {
        // ⚠️ 只重置**当前联系人**这一份 —— 别人账上的钱一分不动。
        //    `loading` 挡掉中途那些 `didSet` 触发的 `persist()`，最后统一落一次盘。
        loading = true
        myBalance = 520.00
        taBalance = 1314.00
        entries = []
        // 余额都回出厂了，共享金库和"本期已用"也一起回零 ——
        // 免得出现"账单没了、但共享余额还挂着一笔对不上的钱"。
        sharedBalance = 0
        closePayMineUsed = 0
        closePayTaUsed = 0
        // 清掉"今天已经发过"的记录，演示时能当场再看一次每日发放。
        bankLastDay = ""
        loading = false
        persist()
    }

    /// 从 `UserDefaults` 重新读一遍余额和流水。
    ///
    /// ⭐ 2026-10-04：搬家恢复时用。`importBackup` 是**非隔离**的（见文件末尾），
    ///    它只写 UserDefaults，写完跳回主线程调这个方法，把 `@Published` 刷新过来。
    func reloadFromDefaults() {
        guard let owner else { return }
        let data = Self.readBlob(owner) ?? OwnerData()
        byOwner[owner] = data
        applyData(data)
    }

    /// 钱怎么显示。**两位小数 + ¥**，全 App 一处说了算。
    static func money(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }
}

// MARK: - 进网盘备份 / 搬家（按联系人分存）

/// 让钱包跟**聊天记录一起进网盘** —— 老板明确的「所有的东西都存百度网盘」。
///
/// ⚠️ 这个钱包本身是 `@MainActor` 的，而 `BackupableStore` 的方法是**同步、
///    非隔离**的（`BackupService` 会在非主线程的路径上调到）。所以这里的方法
///    一律标 `nonisolated`，**只碰 `UserDefaults`**（它自带线程安全），
///    绝不碰 `@Published` —— 导入之后跳回主线程（`reloadFromDefaults`）再刷新。
///
/// ## 包里的结构（2026-10 起）
/// 老版本是**一枚扁平键一个人**那 20 多个 key；现在改成**一个人一份 blob**
/// （`aevis.wallet.v2.<uuid>`）。导出 / 恢复都以「一份 `byOwner` 字典」为准：
///   · 新备份：`Archive.byOwner` 装全部人；下面那些老段是 nil（`encodeIfPresent` 省略）。
///   · 老备份：`byOwner` 缺键 ⇒ nil，`mine/theirs/entries` 有值 ⇒ 认到搬过来的 active 名下。
///   ⚠️ 老扁平键（`aevis.wallet.mine` 那种）**一个没删**，只在本机第一次认人时
///      读一次做迁移（见 `applyOwner` / `legacyData`）。
extension WalletStore: BackupableStore {

    /// 包里这段的名字。**定了就别改** —— 改了的话老备份恢复不回来。
    nonisolated var backupName: String { "wallet" }

    /// 钱包的备份结构。
    ///
    /// 🔴 **所有可能缺键的段一律 `Optional + 默认 nil`** —— Swift 合成的
    ///    `Decodable` **不吃属性默认值**，非可选项缺键会直接抛 `keyNotFound`
    ///    （老备份整条解不出）。只有可选项才走 `decodeIfPresent` → nil。
    ///    ⚠️ `byOwner` 也必须可选项：老备份里根本没有这个键。
    private struct Archive: Codable {
        /// 新结构，一个人一份。老备份没有这个键 ⇒ nil。
        var byOwner: [String: OwnerData]? = nil

        // —— 下面这些**只在读老备份（单人）时非空** ——
        var mine: Double? = nil
        var theirs: Double? = nil
        var entries: [Entry]? = nil

        var bankEnabled: Bool? = nil
        var bankAmount: Double? = nil
        var bankTarget: String? = nil
        var bankLastDay: String? = nil
        var bankShared: Bool? = nil
        var bankSharedBalance: Double? = nil

        var closePayMineEnabled: Bool? = nil
        var closePayMineLimit: Double? = nil
        var closePayMinePeriod: String? = nil
        var closePayMineUsed: Double? = nil
        var closePayMineSince: Double? = nil

        var closePayTaEnabled: Bool? = nil
        var closePayTaLimit: Double? = nil
        var closePayTaPeriod: String? = nil
        var closePayTaUsed: Double? = nil
        var closePayTaSince: Double? = nil

        /// 老备份（单人）那几段 → 一份 `OwnerData`。缺的项退回默认值。
        var legacyOwnerData: OwnerData {
            var data = OwnerData()
            if let mine { data.mine = mine }
            if let theirs { data.theirs = theirs }
            if let entries { data.entries = entries }
            if let bankEnabled { data.bankEnabled = bankEnabled }
            if let bankAmount { data.bankAmount = bankAmount }
            if let bankTarget { data.bankTarget = bankTarget }
            if let bankLastDay { data.bankLastDay = bankLastDay }
            if let bankShared { data.bankShared = bankShared }
            if let bankSharedBalance { data.bankSharedBalance = bankSharedBalance }
            if let closePayMineEnabled { data.closePayMineEnabled = closePayMineEnabled }
            if let closePayMineLimit { data.closePayMineLimit = closePayMineLimit }
            if let closePayMinePeriod { data.closePayMinePeriod = closePayMinePeriod }
            if let closePayMineUsed { data.closePayMineUsed = closePayMineUsed }
            if let closePayMineSince { data.closePayMineSince = closePayMineSince }
            if let closePayTaEnabled { data.closePayTaEnabled = closePayTaEnabled }
            if let closePayTaLimit { data.closePayTaLimit = closePayTaLimit }
            if let closePayTaPeriod { data.closePayTaPeriod = closePayTaPeriod }
            if let closePayTaUsed { data.closePayTaUsed = closePayTaUsed }
            if let closePayTaSince { data.closePayTaSince = closePayTaSince }
            return data
        }
    }

    /// 导出**所有联系人**的钱包 —— 搬家要搬的是全部，不只当前这个。
    /// 直接扫 UserDefaults 里现存的 blob 键（nonisolated，读不到内存缓存 `byOwner`）。
    nonisolated func exportBackup() throws -> Data {
        var flat: [String: OwnerData] = [:]
        for key in Self.existingBlobKeys() {
            let suffix = String(key.dropFirst(walletBlobPrefix.count))
            guard let id = UUID(uuidString: suffix),
                  let data = Self.readBlob(id) else { continue }
            flat[suffix] = data
        }
        return try JSONEncoder().encode(Archive(byOwner: flat))
    }

    nonisolated func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        let defaults = UserDefaults.standard

        // ⚠️ 先清掉本机**所有**现存的钱包 blob，再写导入的 —— 导入语义是「覆盖」。
        //    不清的话，备份里没有的人会残留在本机，看着像"没导干净"。
        for key in Self.existingBlobKeys() {
            defaults.removeObject(forKey: key)
        }

        if let imported = archive.byOwner, !imported.isEmpty {
            // 新备份：逐个人写回各自的 blob。
            for (key, value) in imported {
                guard let id = UUID(uuidString: key),
                      let raw = try? JSONEncoder().encode(value) else { continue }
                defaults.set(raw, forKey: walletBlobKey(id))
            }
        } else if archive.mine != nil || archive.theirs != nil || archive.entries != nil {
            // 老备份（单人）→ 认到搬过来的那个 active。
            // `PersonaStore` 先导完通讯录、`activeID` 已就位（见 `BackupService.restore`）。
            let fallback = PersonaStore.shared.activeID ?? PersonaStore.shared.contacts.first?.id
            if let fallback, let raw = try? JSONEncoder().encode(archive.legacyOwnerData) {
                defaults.set(raw, forKey: walletBlobKey(fallback))
            }
        }

        // 老扁平键从此不再参与 —— 标记迁移过，别让它在切人时又搬一遍盖掉新数据。
        defaults.set(true, forKey: walletLegacyMigratedKey)

        // ⚠️ 界面上的余额 / 流水 / 设置跳回主线程刷新 —— 直接改 @Published 会硬崩。
        Task { @MainActor in
            WalletStore.shared.reloadFromDefaults()
        }
    }
}
