import Foundation
import SwiftUI

/// 「钱包」—— **纯本地的假数据**，不接任何真支付。
///
/// ## 用户要的（2026-09-29 原话）
/// 「你弄个假支付功能，就是你这里有钱包，对面那里也有钱包，知道吗？」
/// 「然后支付功能的话，也是气泡。」
///
/// 所以这个钱包只有两件事：
/// 1. 两个人**各有一个余额**（我 / TA），都存本机；
/// 2. 转账之后**余额真的跟着动**（我的减、TA 的加），气泡上写着"已收款"。
///
/// ⚠️ **别拿它接真钱**。要接真的那套（支付宝 12 元收款）在服务端，
///    跟这个钱包是**两条完全不相干的线** —— 混在一起会出事。
@MainActor
final class WalletStore: ObservableObject {

    static let shared = WalletStore()

    /// 我的余额。默认给个数，别让人一开始看到 0 觉得是坏的。
    @Published var myBalance: Double {
        didSet { UserDefaults.standard.set(myBalance, forKey: Key.mine) }
    }

    /// TA 的余额。她也有钱包（用户明确要的）。
    @Published var taBalance: Double {
        didSet { UserDefaults.standard.set(taBalance, forKey: Key.theirs) }
    }

    private enum Key {
        static let mine = "aevis.wallet.mine"
        static let theirs = "aevis.wallet.theirs"
    }

    /// 转账常用金额（微信那排快捷数字）+ 一个红包的吉利数。
    static let quickAmounts: [Double] = [5.20, 13.14, 52.00, 88.88, 200.00]

    private init() {
        let defaults = UserDefaults.standard
        myBalance = defaults.object(forKey: Key.mine) as? Double ?? 520.00
        taBalance = defaults.object(forKey: Key.theirs) as? Double ?? 1314.00
    }

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
        return value
    }

    /// 她收下我转过去的钱 → 加进她的余额。
    func acceptIncoming(_ amount: Double) {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        taBalance += value
    }

    /// 她不肯收 → 钱退回我的余额。
    func refund(_ amount: Double) {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return }
        myBalance += value
    }

    /// 她转给我（红包 / 她主动给的那种）。**只加不减**，不会把我扣成负的。
    @discardableResult
    func receive(amount: Double) -> Double {
        let value = (amount * 100).rounded() / 100
        guard value > 0 else { return 0 }
        taBalance = max(0, taBalance - value)
        myBalance += value
        return value
    }

    /// 重置成默认（设置里给个「恢复默认」用得上，也方便演示）。
    func reset() {
        myBalance = 520.00
        taBalance = 1314.00
    }

    /// 钱怎么显示。**两位小数 + ¥**，全 App 一处说了算。
    static func money(_ value: Double) -> String {
        String(format: "¥%.2f", value)
    }
}
