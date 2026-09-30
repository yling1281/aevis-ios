import Foundation
import SwiftUI

/// 「钱包」—— **纯本地的假数据**，不接任何真支付。
///
/// ## 用户要的（2026-09-29 原话）
/// 「你弄个假支付功能，就是你这里有钱包，对面那里也有钱包，知道吗？」
/// 「然后支付功能的话，也是气泡。」
///
/// ## ⭐ 2026-10-01：让「她真的给我打钱」成立 + 加流水
/// 用户原话：「**银行卡：能让 AI 真的给内置的虚拟银行卡打钱。**」
///
/// 查下来这里是个洞：`receive()`（她给我转）**早就写好了、却一个调用方都没有**；
/// `ChatStore.appendIncomingTransfer`（她的转账气泡）**同样是死代码**。
/// 也就是说 —— 「她给我打钱」这条路**以前根本不存在**，聊天里也从来不会出现
/// 她发的转账气泡。这次由 `WalletTools` 把那条路接起来，
/// 并补一张**流水**（`entries`）：**每一次我的余额变动都留痕**。
///
/// ## 钱的闭环（自洽，没有凭空印钞）
/// 我转给她 → 她收下 → **她的余额真的变多** → 她就能再转回给我。
/// 她转给我时**她会不够**（`receive` 会拒绝）—— 不是 bug，是设计：
/// 她没钱了就该说没钱，而不是无限给你打钱。
///
/// ⚠️ **别拿它接真钱**。要接真的那套（支付宝 12 元收款）在服务端，
///    跟这个钱包是**两条完全不相干的线** —— 混在一起会出事。
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
    }

    /// 我的余额。默认给个数，别让人一开始看到 0 觉得是坏的。
    @Published var myBalance: Double {
        didSet { UserDefaults.standard.set(myBalance, forKey: Key.mine) }
    }

    /// TA 的余额。她也有钱包（用户明确要的）。
    @Published var taBalance: Double {
        didSet { UserDefaults.standard.set(taBalance, forKey: Key.theirs) }
    }

    /// 流水，**新的在前**。只由 `record()` 改。
    @Published private(set) var entries: [Entry] = []

    private enum Key {
        static let mine = "aevis.wallet.mine"
        static let theirs = "aevis.wallet.theirs"
        static let entries = "aevis.wallet.entries"
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
        BlackBox.log("钱包：我 \(Self.money(myBalance)) / TA \(Self.money(taBalance))"
                     + " · 流水 \(entries.count) 笔")
    }

    // MARK: - 流水

    /// 记一笔。**这是唯一会动 `entries` 的地方** —— 别处别直接改。
    ///
    /// 金额先夹成两位小数再判零：`0.001` 这种"转了但账上没变"的必须挡掉，
    /// 否则流水里会出现一行 ¥0.00，看着像坏的。
    private func record(_ delta: Double, note: String) {
        let value = (delta * 100).rounded() / 100
        guard value != 0 else { return }
        var list = entries
        list.insert(Entry(delta: value, note: note), at: 0)
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

    // MARK: - 转账

    /// 我转给她。返回**实际转出去的金额**（钱不够就转不出来，回 0）。
    ///
    /// ⚠️ 真的会做余额校验 —— 假钱包也要自洽，不然余额变成负数就成了笑话。
    /// ⭐ #23（2026-09-30）：这里**只扣我的钱**，TA 的钱等「她收下」那一刻才加
    ///    （见 `acceptIncoming`）；她不肯收就 `refund` 退回。
    @discardableResult
    func send(amount: Double, note: String = "") -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0, value <= myBalance else { return 0 }
        myBalance -= value
        record(-value, note: note.isEmpty ? "转给 TA（等她收）" : "转给 TA：\(note)")
        return value
    }

    /// 她收下我转过去的钱 → 加进她的余额。
    ///
    /// **不记流水** —— 流水是「我的收支」，这一步没动我一分钱。
    /// 她收没收，聊天里那条气泡自己会变成「已收款」。
    func acceptIncoming(_ amount: Double) {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        taBalance += value
    }

    /// 她不肯收 → 钱退回我的余额。
    func refund(_ amount: Double, note: String = "") {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        myBalance += value
        record(value, note: note.isEmpty ? "TA 没肯收，退回" : note)
    }

    /// 她转给我（她主动给的那种）。
    ///
    /// ⚠️ **2026-10-01 加了「她够不够」的校验**。老写法是
    ///    `taBalance = max(0, taBalance - value)` 然后照加我的 ——
    ///    也就是**她没钱也能给你**，那等于凭空印钞，多转几次她的钱包就废了。
    ///    现在不够就返回 `0`，**调用方要照实把这件事说出来**（别假装成功）。
    @discardableResult
    func receive(amount: Double, note: String = "") -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0, value <= taBalance else { return 0 }
        taBalance -= value
        myBalance += value
        record(value, note: note.isEmpty ? "TA 转给我" : "TA 转给我：\(note)")
        return value
    }

    /// 重置成默认（设置里给个「恢复默认」用得上，也方便演示）。
    /// 流水也一起清掉 —— 余额都回到出厂了，留着旧账单只会对不上。
    func reset() {
        myBalance = 520.00
        taBalance = 1314.00
        entries = []
        UserDefaults.standard.removeObject(forKey: Key.entries)
    }

    /// 钱怎么显示。**两位小数 + ¥**，全 App 一处说了算。
    static func money(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }
}
