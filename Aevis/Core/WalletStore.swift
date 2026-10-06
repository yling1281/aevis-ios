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
        didSet { UserDefaults.standard.set(myBalance, forKey: Key.mine) }
    }

    /// ta 的余额。ta也有钱包（用户明确要的）。
    @Published var taBalance: Double {
        didSet { UserDefaults.standard.set(taBalance, forKey: Key.theirs) }
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
        didSet { UserDefaults.standard.set(bankEnabled, forKey: Key.bankEnabled) }
    }

    /// 每天发多少钱。
    @Published var bankAmount: Double {
        didSet { UserDefaults.standard.set(bankAmount, forKey: Key.bankAmount) }
    }

    /// 发到哪一侧："her"（ta的卡）/ "me"（我的卡）/ "both"（两张卡都发）。
    @Published var bankTarget: String {
        didSet { UserDefaults.standard.set(bankTarget, forKey: Key.bankTarget) }
    }

    /// 最后一次发放是哪天（本地日期 `yyyy-MM-dd`）。空串 = 从来没发过。
    @Published private(set) var bankLastDay: String = "" {
        didSet { UserDefaults.standard.set(bankLastDay, forKey: Key.bankLastDay) }
    }

    /// 家庭共享：打开后每日发放进**共享金库**，不单独进谁的卡。
    @Published var bankShared: Bool {
        didSet { UserDefaults.standard.set(bankShared, forKey: Key.bankShared) }
    }

    /// 家庭共享金库的余额。
    @Published var sharedBalance: Double {
        didSet { UserDefaults.standard.set(sharedBalance, forKey: Key.bankSharedBalance) }
    }

    // MARK: - 亲密付的设置（两个方向各自独立）
    //
    // ⭐ 2026-10-05：亲密付是**双向**的 —— 老板「他也可以给我代付，开亲密付」。
    //    · mine：我给ta开（ta花、**我**付） → 扣 `myBalance`
    //    · ta  ：ta给我开（我花、**ta**付） → 扣 `taBalance`

    /// 我给ta开的亲密付。
    @Published var closePayMineEnabled: Bool {
        didSet { UserDefaults.standard.set(closePayMineEnabled, forKey: Key.closePayMineEnabled) }
    }
    @Published var closePayMineLimit: Double {
        didSet { UserDefaults.standard.set(closePayMineLimit, forKey: Key.closePayMineLimit) }
    }
    @Published var closePayMinePeriod: String {
        didSet { UserDefaults.standard.set(closePayMinePeriod, forKey: Key.closePayMinePeriod) }
    }
    @Published var closePayMineUsed: Double {
        didSet { UserDefaults.standard.set(closePayMineUsed, forKey: Key.closePayMineUsed) }
    }
    private var closePayMineSince: Double = 0 {
        didSet { UserDefaults.standard.set(closePayMineSince, forKey: Key.closePayMineSince) }
    }

    /// ta给我开的亲密付（ta主动给的；用户能关掉）。
    @Published var closePayTaEnabled: Bool {
        didSet { UserDefaults.standard.set(closePayTaEnabled, forKey: Key.closePayTaEnabled) }
    }
    @Published var closePayTaLimit: Double {
        didSet { UserDefaults.standard.set(closePayTaLimit, forKey: Key.closePayTaLimit) }
    }
    @Published var closePayTaPeriod: String {
        didSet { UserDefaults.standard.set(closePayTaPeriod, forKey: Key.closePayTaPeriod) }
    }
    @Published var closePayTaUsed: Double {
        didSet { UserDefaults.standard.set(closePayTaUsed, forKey: Key.closePayTaUsed) }
    }
    private var closePayTaSince: Double = 0 {
        didSet { UserDefaults.standard.set(closePayTaSince, forKey: Key.closePayTaSince) }
    }

    /// 每日发放的轮询定时器。**挂在 WalletStore 自己内部**（不碰 App/ 目录）。
    private var dailyTimer: Timer?

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
        let defaults = UserDefaults.standard
        myBalance = defaults.object(forKey: Key.mine) as? Double ?? 520.00
        taBalance = defaults.object(forKey: Key.theirs) as? Double ?? 1314.00

        if let data = defaults.data(forKey: Key.entries),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        }

        // 虚拟银行 / 亲密付的设置（全新键，老用户拿默认值）
        bankEnabled = defaults.object(forKey: Key.bankEnabled) as? Bool ?? true
        bankAmount = defaults.object(forKey: Key.bankAmount) as? Double ?? 88.00
        let storedTarget = defaults.string(forKey: Key.bankTarget) ?? "her"
        bankTarget = (storedTarget == "me" || storedTarget == "both") ? storedTarget : "her"
        bankLastDay = defaults.string(forKey: Key.bankLastDay) ?? ""
        bankShared = defaults.object(forKey: Key.bankShared) as? Bool ?? false
        sharedBalance = defaults.object(forKey: Key.bankSharedBalance) as? Double ?? 0

        closePayMineEnabled = defaults.object(forKey: Key.closePayMineEnabled) as? Bool ?? false
        closePayMineLimit = defaults.object(forKey: Key.closePayMineLimit) as? Double ?? 2000.00
        let minePeriod = defaults.string(forKey: Key.closePayMinePeriod) ?? "month"
        closePayMinePeriod = (minePeriod == "day") ? "day" : "month"
        closePayMineUsed = defaults.object(forKey: Key.closePayMineUsed) as? Double ?? 0
        closePayMineSince = defaults.object(forKey: Key.closePayMineSince) as? Double ?? 0

        closePayTaEnabled = defaults.object(forKey: Key.closePayTaEnabled) as? Bool ?? false
        closePayTaLimit = defaults.object(forKey: Key.closePayTaLimit) as? Double ?? 2000.00
        let taPeriod = defaults.string(forKey: Key.closePayTaPeriod) ?? "month"
        closePayTaPeriod = (taPeriod == "day") ? "day" : "month"
        closePayTaUsed = defaults.object(forKey: Key.closePayTaUsed) as? Double ?? 0
        closePayTaSince = defaults.object(forKey: Key.closePayTaSince) as? Double ?? 0

        BlackBox.log("钱包：我 \(Self.money(myBalance)) / ta \(Self.money(taBalance))"
                     + " · 流水 \(entries.count) 笔")

        // ⭐ 每日发放：启动先补一次（关机/后台过夜落下的那一笔补上），
        //    之后每 60 秒查一次。定时器挂在 WalletStore 自己内部，
        //    **绝不碰 App/ 目录**（那边别人在同时改）。
        grantDailyIfNeeded()
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.grantDailyIfNeeded() }
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
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Key.entries)
        }
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
        myBalance = 520.00
        taBalance = 1314.00
        entries = []
        UserDefaults.standard.removeObject(forKey: Key.entries)
        // 余额都回出厂了，共享金库和"本期已用"也一起回零 ——
        // 免得出现"账单没了、但共享余额还挂着一笔对不上的钱"。
        sharedBalance = 0
        closePayMineUsed = 0
        closePayTaUsed = 0
        // 清掉"今天已经发过"的记录，演示时能当场再看一次每日发放。
        bankLastDay = ""
    }

    /// 从 `UserDefaults` 重新读一遍余额和流水。
    ///
    /// ⭐ 2026-10-04：搬家恢复时用。`importBackup` 是**非隔离**的（见文件末尾），
    ///    它只写 UserDefaults，写完跳回主线程调这个方法，把 `@Published` 刷新过来。
    func reloadFromDefaults() {
        let defaults = UserDefaults.standard
        myBalance = defaults.object(forKey: Key.mine) as? Double ?? 520.00
        taBalance = defaults.object(forKey: Key.theirs) as? Double ?? 1314.00
        if let data = defaults.data(forKey: Key.entries),
           let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
        } else {
            entries = []
        }

        // ⭐ 2026-10-05：虚拟银行 / 亲密付的设置也一起刷回来 —— 不然 `importBackup`
        //    把设置写进了 UserDefaults，界面上的开关 / 额度还是旧值（只有余额和流水被刷新）。
        bankEnabled = defaults.object(forKey: Key.bankEnabled) as? Bool ?? true
        bankAmount = defaults.object(forKey: Key.bankAmount) as? Double ?? 88.00
        let storedTarget = defaults.string(forKey: Key.bankTarget) ?? "her"
        bankTarget = (storedTarget == "me" || storedTarget == "both") ? storedTarget : "her"
        bankLastDay = defaults.string(forKey: Key.bankLastDay) ?? ""
        bankShared = defaults.object(forKey: Key.bankShared) as? Bool ?? false
        sharedBalance = defaults.object(forKey: Key.bankSharedBalance) as? Double ?? 0

        closePayMineEnabled = defaults.object(forKey: Key.closePayMineEnabled) as? Bool ?? false
        closePayMineLimit = defaults.object(forKey: Key.closePayMineLimit) as? Double ?? 2000.00
        let minePeriod = defaults.string(forKey: Key.closePayMinePeriod) ?? "month"
        closePayMinePeriod = (minePeriod == "day") ? "day" : "month"
        closePayMineUsed = defaults.object(forKey: Key.closePayMineUsed) as? Double ?? 0
        closePayMineSince = defaults.object(forKey: Key.closePayMineSince) as? Double ?? 0

        closePayTaEnabled = defaults.object(forKey: Key.closePayTaEnabled) as? Bool ?? false
        closePayTaLimit = defaults.object(forKey: Key.closePayTaLimit) as? Double ?? 2000.00
        let taPeriod = defaults.string(forKey: Key.closePayTaPeriod) ?? "month"
        closePayTaPeriod = (taPeriod == "day") ? "day" : "month"
        closePayTaUsed = defaults.object(forKey: Key.closePayTaUsed) as? Double ?? 0
        closePayTaSince = defaults.object(forKey: Key.closePayTaSince) as? Double ?? 0
    }

    /// 钱怎么显示。**两位小数 + ¥**，全 App 一处说了算。
    static func money(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }
}

// MARK: - 进网盘备份（2026-10-04）

/// 让虚拟银行跟**聊天记录一起进网盘** —— 老板明确的「所有的东西都存百度网盘」。
///
/// ⚠️ 这个钱包本身是 `@MainActor` 的，而 `BackupableStore` 的方法是**同步、
///    非隔离**的（`BackupService` 会在非主线程的路径上调到）。所以这三个方法
///    一律标 `nonisolated`，**只碰 `UserDefaults`**（它自带线程安全），
///    绝不碰 `@Published` —— 导入之后跳回主线程再刷新。
///
/// ⚠️ 键名一个都不能改（`aevis.wallet.mine` / `.theirs` / `.entries`）——
///    那是已经落盘的数据，改了老用户的钱包当场清零。
extension WalletStore: BackupableStore {

    /// 包里这段的名字。**定了就别改** —— 改了的话老备份恢复不回来。
    nonisolated var backupName: String { "wallet" }

    /// 钱包的存档结构。`Entry` 复用类里那个。
    private struct Archive: Codable {
        var mine: Double = 520.00
        var theirs: Double = 1314.00
        var entries: [Entry] = []

        // ⭐ 2026-10-05 新增：虚拟银行 + 亲密付的设置也要跟着进网盘。
        //    ⚠️ 一律 **Optional + 默认值 `nil`** —— 老备份里没有这些键，
        //       这样才能「缺键 → nil」地解出来（不带默认值会让老备份整条解不出）。
        //    导入时对 `nil` 一律**跳过**（保留现状），而不是写回成 0 / false。
        // 虚拟银行（每日发放 + 家庭共享）
        var bankEnabled: Bool? = nil
        var bankAmount: Double? = nil
        var bankTarget: String? = nil
        var bankLastDay: String? = nil
        var bankShared: Bool? = nil
        var bankSharedBalance: Double? = nil
        // 亲密付 · 方向一（我给ta开 / 扣我的）
        var closePayMineEnabled: Bool? = nil
        var closePayMineLimit: Double? = nil
        var closePayMinePeriod: String? = nil
        var closePayMineUsed: Double? = nil
        var closePayMineSince: Double? = nil
        // 亲密付 · 方向二（ta给我开 / 扣ta的）
        var closePayTaEnabled: Bool? = nil
        var closePayTaLimit: Double? = nil
        var closePayTaPeriod: String? = nil
        var closePayTaUsed: Double? = nil
        var closePayTaSince: Double? = nil
    }

    nonisolated func exportBackup() throws -> Data {
        let defaults = UserDefaults.standard
        let archive = Archive(
            mine: defaults.object(forKey: Key.mine) as? Double ?? 520.00,
            theirs: defaults.object(forKey: Key.theirs) as? Double ?? 1314.00,
            entries: defaults.data(forKey: Key.entries).flatMap {
                try? JSONDecoder().decode([Entry].self, from: $0)
            } ?? [],
            bankEnabled: defaults.object(forKey: Key.bankEnabled) as? Bool,
            bankAmount: defaults.object(forKey: Key.bankAmount) as? Double,
            bankTarget: defaults.string(forKey: Key.bankTarget),
            bankLastDay: defaults.string(forKey: Key.bankLastDay),
            bankShared: defaults.object(forKey: Key.bankShared) as? Bool,
            bankSharedBalance: defaults.object(forKey: Key.bankSharedBalance) as? Double,
            closePayMineEnabled: defaults.object(forKey: Key.closePayMineEnabled) as? Bool,
            closePayMineLimit: defaults.object(forKey: Key.closePayMineLimit) as? Double,
            closePayMinePeriod: defaults.string(forKey: Key.closePayMinePeriod),
            closePayMineUsed: defaults.object(forKey: Key.closePayMineUsed) as? Double,
            closePayMineSince: defaults.object(forKey: Key.closePayMineSince) as? Double,
            closePayTaEnabled: defaults.object(forKey: Key.closePayTaEnabled) as? Bool,
            closePayTaLimit: defaults.object(forKey: Key.closePayTaLimit) as? Double,
            closePayTaPeriod: defaults.string(forKey: Key.closePayTaPeriod),
            closePayTaUsed: defaults.object(forKey: Key.closePayTaUsed) as? Double,
            closePayTaSince: defaults.object(forKey: Key.closePayTaSince) as? Double
        )
        return try JSONEncoder().encode(archive)
    }

    nonisolated func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        let defaults = UserDefaults.standard
        defaults.set(archive.mine, forKey: Key.mine)
        defaults.set(archive.theirs, forKey: Key.theirs)
        if let list = try? JSONEncoder().encode(archive.entries) {
            defaults.set(list, forKey: Key.entries)
        }
        // ⭐ 2026-10-05：虚拟银行 / 亲密付的设置（老备份是 nil → **不写**，保留现状）。
        if let value = archive.bankEnabled { defaults.set(value, forKey: Key.bankEnabled) }
        if let value = archive.bankAmount { defaults.set(value, forKey: Key.bankAmount) }
        if let value = archive.bankTarget { defaults.set(value, forKey: Key.bankTarget) }
        if let value = archive.bankLastDay { defaults.set(value, forKey: Key.bankLastDay) }
        if let value = archive.bankShared { defaults.set(value, forKey: Key.bankShared) }
        if let value = archive.bankSharedBalance {
            defaults.set(value, forKey: Key.bankSharedBalance)
        }
        if let value = archive.closePayMineEnabled {
            defaults.set(value, forKey: Key.closePayMineEnabled)
        }
        if let value = archive.closePayMineLimit {
            defaults.set(value, forKey: Key.closePayMineLimit)
        }
        if let value = archive.closePayMinePeriod {
            defaults.set(value, forKey: Key.closePayMinePeriod)
        }
        if let value = archive.closePayMineUsed {
            defaults.set(value, forKey: Key.closePayMineUsed)
        }
        if let value = archive.closePayMineSince {
            defaults.set(value, forKey: Key.closePayMineSince)
        }
        if let value = archive.closePayTaEnabled {
            defaults.set(value, forKey: Key.closePayTaEnabled)
        }
        if let value = archive.closePayTaLimit {
            defaults.set(value, forKey: Key.closePayTaLimit)
        }
        if let value = archive.closePayTaPeriod {
            defaults.set(value, forKey: Key.closePayTaPeriod)
        }
        if let value = archive.closePayTaUsed {
            defaults.set(value, forKey: Key.closePayTaUsed)
        }
        if let value = archive.closePayTaSince {
            defaults.set(value, forKey: Key.closePayTaSince)
        }
        // ⚠️ 界面上的余额 / 流水 / 设置跳回主线程刷新 —— 直接改 @Published 会硬崩。
        Task { @MainActor in
            WalletStore.shared.reloadFromDefaults()
        }
    }
}

