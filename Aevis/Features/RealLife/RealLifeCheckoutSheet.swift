import SwiftUI
import Foundation

// 「真实生活」下订单前的**结算 sheet**。
//
// 规矩：
//   · 明细 + 合计（**含 `deliveryFee`**）+ 起送门槛校验。
//   · 地址给一个像样的默认值，可改。
//   · 付款方式**四选一**：我自己付 / 亲密付（我开的）/ 亲密付（ta 开的）/ ta 代付。
//     不能选的那些**置灰并写明原因**（未开通 / 额度不够 / 余额不足）。
//   · 提交时**先按选中的方式真扣钱**（`WalletStore`），返回 0（没付成）就当场拦下、
//     **绝不落单**；付成功才 `RealLifeStore.shared.placeOrder(...)`。

/// 结算页里可选的四种付款方式。
///
/// 单独抽成 enum，是因为**四条各自"记谁付的 + 往哪个方向扣 + 调哪个钱包方法"全都不同**，
/// 摊在 `if / else` 里迟早写歪。用它一张表收口：界面文案、`PaidBy`、方向、调用点都从这里取。
private enum PayOption: String, CaseIterable, Identifiable {
    case me          // 我自己付
    case closeMine   // 亲密付（我开的）—— 扣我的余额
    case closeTa     // 亲密付（ta 开的）—— 扣 ta 的余额
    case proxyTa     // ta 代付（一次性）

    var id: String { rawValue }

    /// 行上的主文案。`PaidBy.closePay` / `.proxy` 的 `title` 分不出方向，所以界面自己写全。
    var title: String {
        switch self {
        case .me: return "我自己付"
        case .closeMine: return "亲密付（我开的）"
        case .closeTa: return "亲密付（ta 开的）"
        case .proxyTa: return "ta 代付"
        }
    }

    /// 行首的 SF Symbol 图标名。
    var icon: String {
        switch self {
        case .me: return "creditcard"
        case .closeMine: return "heart.circle"
        case .closeTa: return "heart.circle.fill"
        case .proxyTa: return "person.2.circle"
        }
    }

    /// 存进订单的「谁付的」。
    var paidBy: PaidBy {
        switch self {
        case .me: return .me
        case .closeMine, .closeTa: return .closePay
        case .proxyTa: return .proxy
        }
    }

    /// 亲密付 / 代付的**方向**（`"mine"` / `"ta"`）；我自己付时留 `nil`。
    var payDirection: String? {
        switch self {
        case .me: return nil
        case .closeMine: return "mine"
        case .closeTa: return "ta"
        case .proxyTa: return "ta"
        }
    }
}

struct CheckoutSheet: View {

    let shop: Shop
    let items: [OrderItem]
    var onPlaced: (Order) -> Void

    @ObservedObject private var store = RealLifeStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var wallet = WalletStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var address: String = CheckoutSheet.defaultAddress
    @State private var submitting = false
    /// 当前选中的付款方式。进来默认「我自己付」，不可选时 `onAppear` 会挑第一个能用的。
    @State private var selectedOption: PayOption = .me
    /// 没付成时页面上要显示的那句话。**只有付失败才会被赋值**。
    @State private var errorText: String?

    /// 地址默认值 —— 给个像样的，用户基本不用改。
    static let defaultAddress = "幸福路 88 号 · 云顶小区 3 栋 1201"

    private var accent: Color { settings.accentColor }

    private var subtotal: Double { items.reduce(0) { $0 + $1.subtotal } }
    private var fee: Double { shop.deliveryFee }
    private var payable: Double { RealLifeFormat.payable(subtotal, deliveryFee: fee) }
    private var reachedMinimum: Bool { subtotal >= shop.minOrder }
    private var shortfall: Double { max(0, shop.minOrder - subtotal) }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        !items.isEmpty && reachedMinimum && !trimmedAddress.isEmpty && !submitting
            && blockReason(selectedOption) == nil
    }

    private var addressTitle: String {
        shop.kind == .food ? "送餐地址" : "收货地址"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AevisBackground().ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        itemsCard
                        addressCard
                        paymentCard

                        if !reachedMinimum {
                            minOrderHint
                        }

                        submitButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("确认订单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                // 进来先按周期检查一次亲密付额度 —— 免得界面上"本期已用"还停在上一期，
                // 那样置灰判断会拿旧数据去卡这一期的单。
                wallet.resetClosePayPeriodIfNeeded()
                // 默认那项不可选时自动挑第一个能选的 —— 免得一进来就卡在灰项上、动都动不了。
                if blockReason(selectedOption) != nil,
                   let first = PayOption.allCases.first(where: { blockReason($0) == nil }) {
                    selectedOption = first
                }
            }
        }
    }

    // MARK: - 明细 + 合计

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(shop.logo).font(.aevis(22))
                Text(shop.name)
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            Divider()

            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.aevis(13.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("×\(item.count)")
                        .font(.aevisMono(12))
                        .foregroundStyle(.secondary)
                    Text("¥" + RealLifeFormat.money(item.subtotal))
                        .font(.aevisMono(13))
                        .foregroundStyle(.primary)
                }
            }

            Divider()

            amountRow("商品小计", "¥" + RealLifeFormat.money(subtotal))
            amountRow("配送费", RealLifeFormat.delivery(shop), value: "¥" + RealLifeFormat.money(fee))

            Divider()

            amountRow("应付", "¥" + RealLifeFormat.money(payable), emphasize: true)
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func amountRow(_ title: String,
                           _ hint: String,
                           value: String,
                           emphasize: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.aevis(emphasize ? 14.5 : 13.5, weight: emphasize ? .semibold : .regular))
                .foregroundStyle(emphasize ? Color.primary : Color.secondary)
            if !hint.isEmpty {
                Text(hint)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.aevisMono(emphasize ? 16 : 13.5, weight: emphasize ? .semibold : .regular))
                .foregroundStyle(emphasize ? Color.primary : Color.secondary)
        }
    }

    /// 「商品小计」那种没有右侧小字的行 —— 复用上面那个，hint 传空即可。
    private func amountRow(_ title: String, _ value: String) -> some View {
        amountRow(title, "", value: value)
    }

    // MARK: - 地址

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(addressTitle)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            TextField(addressTitle, text: $address, axis: .vertical)
                .lineLimit(1...2)
                .font(.aevis(14))
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 付款方式（四选一）

    private var paymentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("付款方式")
                .font(.aevis(12))
                .foregroundStyle(.secondary)

            ForEach(PayOption.allCases) { option in
                paymentRow(option)
            }

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.aevis(12))
                        .foregroundStyle(Color.orange)
                    Text(errorText)
                        .font(.aevis(12, weight: .medium))
                        .foregroundStyle(Color.orange)
                    Spacer(minLength: 8)
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    /// 一行付款方式：图标 + 文案 + 余额 / 额度小字 + 选中打勾；不能选的置灰并写明原因。
    private func paymentRow(_ option: PayOption) -> some View {
        let reason = blockReason(option)
        let selectable = reason == nil
        let selected = selectable && selectedOption == option
        return Button {
            selectedOption = option
            errorText = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: option.icon)
                    .font(.aevis(15))
                    .foregroundStyle(selectable ? accent : Color.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(selectable ? Color.primary : Color.secondary)
                    Text(detailText(option))
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 8)

                if let reason {
                    Text(reason)
                        .font(.aevis(11))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.aevis(16))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? accent.opacity(0.10) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
    }

    /// 这个付款方式现在**为什么不能选**（能选就返回 `nil`）。
    ///
    /// 判据一律走 `WalletStore` 的只读预检 `can*`，**不自己另立一套** ——
    /// 界面说"能选"、结算却返回 0 的那种自相矛盾，就是这么来的。
    private func blockReason(_ option: PayOption) -> String? {
        switch option {
        case .me:
            return wallet.canSpendAsMe(payable) ? nil : "我的余额不足"
        case .closeMine:
            guard wallet.closePayMineEnabled else { return "未开通亲密付" }
            guard wallet.canClosePay(.mine, amount: payable) else {
                return overLimit(.mine) ? "本期额度不够" : "我的余额不足"
            }
            return nil
        case .closeTa:
            guard wallet.closePayTaEnabled else { return "未开通亲密付" }
            guard wallet.canClosePay(.ta, amount: payable) else {
                return overLimit(.ta) ? "本期额度不够" : "ta 的余额不足"
            }
            return nil
        case .proxyTa:
            return wallet.canProxyPay(.ta, amount: payable) ? nil : "ta 的余额不足"
        }
    }

    /// 这笔金额会不会顶到该方向的**本期额度上限**（口径与 `canClosePay` 里那一步一致，
    /// 所以两边都留 `+ 0.001` 余量）。
    private func overLimit(_ dir: ClosePayDirection) -> Bool {
        switch dir {
        case .mine: return wallet.closePayMineUsed + payable > wallet.closePayMineLimit + 0.001
        case .ta: return wallet.closePayTaUsed + payable > wallet.closePayTaLimit + 0.001
        }
    }

    /// 每行下面的余额 / 额度小字。金额一律走 `WalletStore.money(...)`，只此一处口径。
    private func detailText(_ option: PayOption) -> String {
        switch option {
        case .me:
            return "余额 " + WalletStore.money(wallet.myBalance)
        case .closeMine:
            guard wallet.closePayMineEnabled else { return "未开通" }
            let left = max(0, wallet.closePayMineLimit - wallet.closePayMineUsed)
            return "剩 " + WalletStore.money(left) + " · 余额 " + WalletStore.money(wallet.myBalance)
        case .closeTa:
            guard wallet.closePayTaEnabled else { return "未开通" }
            let left = max(0, wallet.closePayTaLimit - wallet.closePayTaUsed)
            return "剩 " + WalletStore.money(left) + " · 余额 " + WalletStore.money(wallet.taBalance)
        case .proxyTa:
            return "余额 " + WalletStore.money(wallet.taBalance)
        }
    }

    /// 没付成时给用户的一句话（说清是哪一项的问题）。
    private func failHint(_ option: PayOption) -> String {
        (blockReason(option) ?? "这一笔没付成") + " —— 订单没下，换一种付款方式试试。"
    }

    // MARK: - 起送提示

    private var minOrderHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.aevis(12))
                .foregroundStyle(Color.orange)
            Text("还差 ¥" + RealLifeFormat.money(shortfall) + " 起送")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(Color.orange)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .aevisGlass(cornerRadius: 14)
    }

    // MARK: - 提交

    private var submitButton: some View {
        Button {
            submit()
        } label: {
            Text(submitTitle)
                .font(.aevis(15, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(canSubmit ? accent : Color.secondary.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
    }

    private var submitTitle: String {
        if !reachedMinimum {
            return "还差 ¥" + RealLifeFormat.money(shortfall) + " 起送"
        }
        return "提交订单 ¥" + RealLifeFormat.money(payable)
    }

    private func submit() {
        guard canSubmit else { return }

        // ⓪ 🔴 **扣钱之前**先确认这单确实下得了 —— 判据与 `placeOrder` 开头那两个 guard
        //    逐字一致（`store.canPlaceOrder`）。顺序绝不能反：反了就等于"钱扣了、订单没落"。
        guard store.canPlaceOrder(shopID: shop.id, items: items) else {
            errorText = "这笔订单现在下不了，钱没扣。"
            return
        }

        submitting = true
        errorText = nil

        let amount = payable               // 沿用本页已有的「应付」口径，别另算
        let option = selectedOption

        // ① 先按选中的方式**真扣钱**。
        let paid: Double
        switch option {
        case .me:
            paid = wallet.spendAsMe(amount: amount,
                                    reason: shop.name,
                                    source: shop.kind == .food ? "外卖" : "购物")
        case .closeMine:
            paid = wallet.closePaySpend(.mine, amount: amount, reason: shop.name)
        case .closeTa:
            paid = wallet.closePaySpend(.ta, amount: amount, reason: shop.name)
        case .proxyTa:
            paid = wallet.proxyPay(.ta, amount: amount, reason: shop.name)
        }

        // ② 🔴 返 0 就是**没付成** —— 当场拦下：既不 placeOrder，也不 dismiss。
        guard paid > 0 else {
            submitting = false
            errorText = failHint(option)
            return
        }

        // ③ 付成功才落单，然后照原来那样回调和关闭。
        let order = store.placeOrder(shopID: shop.id,
                                     items: items,
                                     paidBy: option.paidBy,
                                     payDirection: option.payDirection,
                                     addressHint: trimmedAddress)
        submitting = false
        if let order {
            onPlaced(order)
            dismiss()
        } else {
            // 走到这里理论上不可能（扣钱前已用 `canPlaceOrder` 把过关），但真到了就**如实说**：
            // 钱扣了、订单没落成。⚠️ **不谎称"已退回"**（我们并没有退款 API，别承诺没做的事）。
            errorText = "订单没落成，请稍后再试。"
        }
    }
}
