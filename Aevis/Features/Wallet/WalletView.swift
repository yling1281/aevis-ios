import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「钱包」页 —— 转账 / 红包都从这儿发出去。
///
/// 用户原话（2026-09-29）：
/// 「你弄个假支付功能，就是你这里有钱包，对面那里也有钱包」
/// 「然后支付功能的话，也是气泡」
///
/// ⚠️ **全是本地假数据**（`WalletStore`），不接任何真支付。
///    真钱那套在服务端（支付宝 12 元收款），跟这里没有关系。
struct WalletView: View {

    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var noteText = ""
    @State private var isRedPacket = false
    @State private var note: String?

    // 虚拟银行 / 亲密付 / 代付的输入与提示（全是本页局部状态）
    @State private var bankAmountText = ""
    @State private var closePayMineLimitText = ""
    @State private var closePayTaLimitText = ""
    @State private var proxyAmountText = ""
    @State private var proxyWho = "mine"
    @State private var proxyNote: String?

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "ta" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    balances
                    picker
                    amountField
                    if !isRedPacket { noteField }
                    sendButton

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    bankSection
                    closePaySection
                    proxyPaySection

                    statement

                    // ⚠️ 拼接出来的字符串**必须包 LocalizedStringKey**，
                    //    否则 Text 走的是 `Text(String)` 那个重载，
                    //    `**加粗**` 不会解析 —— 截图里星号就明晃晃地露着
                    //    （2026-09-29 真栽了，检查器 R17 已补上这条）。
                    Text(LocalizedStringKey("这是**本机上的假钱包** —— 余额和转账都只存在这台手机上，"
                                            + "不接任何真的支付，也不会真的扣谁的钱。"))
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("钱包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 我的余额
    //
    // ⚠️ #24（用户 2026-09-30）：钱包页**不再显示 ta 的余额** ——
    //    看 ta 的钱包改成从聊天页右上角「ta 的资料」里点进去。

    private var balances: some View {
        balanceCard(title: "我的钱包", value: wallet.myBalance, mine: true)
    }

    private func balanceCard(title: String, value: Double, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
            Text(WalletStore.money(value))
                .font(.aevis(21, weight: .semibold))
                .foregroundStyle(mine ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 16)
    }

    // MARK: - 转账 / 红包

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach([false, true], id: \.self) { red in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isRedPacket = red }
                } label: {
                    Text(red ? "红包" : "转账")
                        .font(.aevis(13, weight: isRedPacket == red ? .semibold : .regular))
                        .foregroundStyle(isRedPacket == red ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(isRedPacket == red ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .aevisGlass(cornerRadius: 14)
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("金额")
                .font(.aevis(12))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("¥")
                    .font(.aevis(19, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .font(.aevis(19, weight: .medium))
                    .keyboardType(.decimalPad)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // 微信那种快捷金额
            HStack(spacing: 8) {
                ForEach(WalletStore.quickAmounts, id: \.self) { value in
                    Button {
                        amountText = String(format: "%.2f", value)
                    } label: {
                        Text(Self.shortMoney(value))
                            .font(.aevis(12.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .aevisGlass(cornerRadius: 11)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("附言（可以不写）")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            TextField("说点什么…", text: $noteText, axis: .vertical)
                .lineLimit(1...3)
                .font(.aevis(14.5))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            HStack(spacing: 8) {
                Text(isRedPacket ? "塞进红包" : "转给\(personaName)")
                    .font(.aevis(15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 流水
    //
    // ⭐ 2026-10-01 新增。用户要的「银行卡」那个感觉 —— 光有余额不够，
    //    得能看见**钱去哪儿了**。
    //
    // ⚠️ 这里只列**我的收支**（`delta != 0`）：ta收下我的转账、ta自己的余额变多，
    //    都**不进这张表**。理由写在 `WalletStore.acceptIncoming` 上 ——
    //    流水讲的是"我这边进出了多少"，把别人的余额混进来只会越看越糊涂。

    private var statement: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("流水")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !wallet.entries.isEmpty {
                    Text("\(wallet.entries.count) 笔")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if wallet.entries.isEmpty {
                Text("还没有进出账。你给 ta 转一笔，或者等 ta 给你转 —— "
                     + "两边都是真的动余额。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            } else {
                // 新的在前（`WalletStore.record` 是 insert(at: 0)），所以直接取前 30。
                ForEach(Array(wallet.entries.prefix(30))) { entry in
                    statementRow(entry)
                }
                if wallet.entries.count > 30 {
                    Text("只显示最近 30 笔。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                        .padding(.bottom, 12)
                }
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func statementRow(_ entry: WalletStore.Entry) -> some View {
        return HStack(spacing: 10) {
            Image(systemName: Self.entryIcon(entry))
                .font(.aevis(12, weight: .medium))
                .foregroundStyle(Self.entryTint(entry))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.note)
                        .font(.aevis(13.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let source = entry.source, !source.isEmpty {
                        sourceBadge(source)
                    }
                }
                Text(WalletStore.shortTime(entry.date))
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            // 进账用红色、出账用正文色 —— 微信零钱明细也是这个读法。
            // ⚠️「ta的卡 / 共享金库」那几笔**不动我的余额**，用次级色区分，
            //    免得把"+88（打到ta的卡）"误当成自己钱包涨了。
            Text(WalletStore.signedMoney(entry.delta))
                .font(.aevisMono(13.5))
                .foregroundStyle(Self.entryTint(entry))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// 流水行左边的小图标：ta自己挣的 / 共享金库的用「银行」，我的进出发用箭头。
    private static func entryIcon(_ entry: WalletStore.Entry) -> String {
        if entry.side == "her" || entry.side == "shared" { return "building.columns" }
        return WalletStore.isIncome(entry) ? "arrow.down.left" : "arrow.up.right"
    }

    /// 流水金额的颜色：我的进账红、我的出账正文色；ta / 共享的一律次级色。
    private static func entryTint(_ entry: WalletStore.Entry) -> Color {
        if entry.side == "her" || entry.side == "shared" { return Color.secondary }
        return WalletStore.isIncome(entry) ? Color.red : Color.primary
    }

    /// 来源小标签（"每日发放" / "工资" / "亲密付" / "代付" …）。
    private func sourceBadge(_ text: String) -> some View {
        Text(text)
            .font(.aevis(10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    // MARK: - 虚拟银行（每日发放）
    //
    // ⭐ 2026-10-05：老板要的「虚拟银行」—— 每天固定发一笔钱，金额他设，
    //    可以打到ta的卡 / 打到我的卡 / 两张卡都发，还能进「家庭共享金库」。

    private static let bankTargets = ["her", "me", "both"]

    private func bankTargetLabel(_ target: String) -> String {
        switch target {
        case "me": return "打到我的卡"
        case "both": return "两张都发"
        default: return "打到\(personaName)的卡"
        }
    }

    private var bankSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("虚拟银行 · 每日发放")
                    .font(.aevis(13, weight: .medium))
                Spacer(minLength: 8)
                Toggle("", isOn: $wallet.bankEnabled)
                    .labelsHidden()
            }

            Text("每天自动发一笔钱到你选的卡。只在本机模拟，不接真银行。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("每日金额")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("¥")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("88", text: $bankAmountText)
                    .font(.aevis(15, weight: .medium))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 96)
            }

            HStack(spacing: 6) {
                ForEach(Self.bankTargets, id: \.self) { target in
                    Button {
                        wallet.bankTarget = target
                    } label: {
                        Text(bankTargetLabel(target))
                            .font(.aevis(12.5, weight: wallet.bankTarget == target ? .semibold : .regular))
                            .foregroundStyle(wallet.bankTarget == target ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(wallet.bankTarget == target ? 0.10 : 0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Text("家庭共享（发进共用金库）")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle("", isOn: $wallet.bankShared)
                    .labelsHidden()
            }

            if wallet.bankShared {
                HStack(spacing: 8) {
                    Text("共享金库余额")
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(WalletStore.money(wallet.sharedBalance))
                        .font(.aevisMono(13))
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: wallet.didGrantToday ? "checkmark.circle.fill" : "clock")
                    .font(.aevis(12, weight: .medium))
                    .foregroundStyle(wallet.didGrantToday ? Color.green : Color.secondary)
                Text(wallet.didGrantToday ? "今天已经发过啦" : "今天还没发")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
        .onAppear {
            if bankAmountText.isEmpty { bankAmountText = Self.shortMoney(wallet.bankAmount) }
        }
        .onChange(of: bankAmountText) { _, newValue in
            let cleaned = newValue.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let value = Double(cleaned), value >= 0, value != wallet.bankAmount {
                wallet.bankAmount = value
            }
        }
    }

    // MARK: - 亲密付（双向）

    private static let closePayPeriods = ["month", "day"]

    private func closePayProgress(used: Double, limit: Double) -> Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    /// 开关走自定义 Binding：打开时带上当前额度/周期**真正开通**，关闭就关。
    private func closePayToggle(dir: WalletStore.ClosePayDirection,
                                limitText: String) -> Binding<Bool> {
        Binding(
            get: {
                dir == .mine ? wallet.closePayMineEnabled : wallet.closePayTaEnabled
            },
            set: { on in
                guard on else {
                    wallet.closeClosePay(dir)
                    return
                }
                let cleaned = limitText.replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let typed = Double(cleaned) ?? 0
                let fallback = (dir == .mine) ? wallet.closePayMineLimit : wallet.closePayTaLimit
                let period = (dir == .mine) ? wallet.closePayMinePeriod : wallet.closePayTaPeriod
                wallet.openClosePay(dir, limit: typed > 0 ? typed : fallback, period: period)
            }
        )
    }

    /// 一组亲密付：标题 + 开关 +（开通时）额度 / 周期 / 本期进度。
    private func closePayGroup(dir: WalletStore.ClosePayDirection,
                               title: String,
                               limitText: Binding<String>) -> some View {
        let enabled = (dir == .mine) ? wallet.closePayMineEnabled : wallet.closePayTaEnabled
        let limit = (dir == .mine) ? wallet.closePayMineLimit : wallet.closePayTaLimit
        let used = (dir == .mine) ? wallet.closePayMineUsed : wallet.closePayTaUsed
        let period = (dir == .mine) ? wallet.closePayMinePeriod : wallet.closePayTaPeriod
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.aevis(12.5, weight: .medium))
                Spacer(minLength: 8)
                Toggle("", isOn: closePayToggle(dir: dir, limitText: limitText.wrappedValue))
                    .labelsHidden()
            }

            if enabled {
                HStack(spacing: 6) {
                    Text("额度")
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("¥")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("2000", text: limitText)
                        .font(.aevis(15, weight: .medium))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                }

                HStack(spacing: 6) {
                    ForEach(Self.closePayPeriods, id: \.self) { item in
                        Button {
                            setClosePayPeriod(dir, period: item)
                        } label: {
                            Text(item == "day" ? "每日" : "每月")
                                .font(.aevis(12.5, weight: period == item ? .semibold : .regular))
                                .foregroundStyle(period == item ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.primary.opacity(period == item ? 0.10 : 0))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("本期已用")
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(WalletStore.money(used)) / \(WalletStore.money(limit))")
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: closePayProgress(used: used, limit: limit))
                }
            }
        }
    }

    private func setClosePayPeriod(_ dir: WalletStore.ClosePayDirection, period: String) {
        if dir == .mine {
            wallet.closePayMinePeriod = period
        } else {
            wallet.closePayTaPeriod = period
        }
    }

    private func applyClosePayLimit(_ text: String, to dir: WalletStore.ClosePayDirection) {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else { return }
        if dir == .mine {
            if value != wallet.closePayMineLimit { wallet.closePayMineLimit = value }
        } else if value != wallet.closePayTaLimit {
            wallet.closePayTaLimit = value
        }
    }

    private var closePaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("亲密付")
                .font(.aevis(13, weight: .medium))

            Text("开个额度，刷卡方花钱就从付款方的余额里扣；每期额度用完就等下一期。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            closePayGroup(dir: .mine,
                          title: "我给\(Pronoun.current)开的（\(Pronoun.current)花、我付）",
                          limitText: $closePayMineLimitText)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            closePayGroup(dir: .ta,
                          title: "\(Pronoun.current)给我开的（我花、\(Pronoun.current)付）",
                          limitText: $closePayTaLimitText)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
        .onAppear {
            // 进来先按周期检查一次 —— 免得界面上"本期已用"还停在上一期的数字。
            wallet.resetClosePayPeriodIfNeeded()
            if closePayMineLimitText.isEmpty {
                closePayMineLimitText = Self.shortMoney(wallet.closePayMineLimit)
            }
            if closePayTaLimitText.isEmpty {
                closePayTaLimitText = Self.shortMoney(wallet.closePayTaLimit)
            }
        }
        .onChange(of: closePayMineLimitText) { _, newValue in
            applyClosePayLimit(newValue, to: .mine)
        }
        .onChange(of: closePayTaLimitText) { _, newValue in
            applyClosePayLimit(newValue, to: .ta)
        }
    }

    // MARK: - 代付（双向）

    private static let proxyWhoKeys = ["mine", "ta"]

    private func proxyLabel(_ key: String) -> String {
        key == "ta" ? "\(Pronoun.current)替我付" : "我替\(Pronoun.current)付"
    }

    private var proxyPaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("代付")
                .font(.aevis(13, weight: .medium))
            Text("一次性，从付款方的余额扣，不占亲密付额度。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(Self.proxyWhoKeys, id: \.self) { key in
                    Button {
                        proxyWho = key
                    } label: {
                        Text(proxyLabel(key))
                            .font(.aevis(12.5, weight: proxyWho == key ? .semibold : .regular))
                            .foregroundStyle(proxyWho == key ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(proxyWho == key ? 0.10 : 0))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 6) {
                Text("¥")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("金额", text: $proxyAmountText)
                    .font(.aevis(15, weight: .medium))
                    .keyboardType(.decimalPad)
                Spacer(minLength: 8)
                Button {
                    doProxyPay()
                } label: {
                    Text("代付")
                        .font(.aevis(13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }

            if let proxyNote {
                Text(proxyNote)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func doProxyPay() {
        let cleaned = proxyAmountText.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else {
            proxyNote = "先填个金额（比如 38）。"
            return
        }
        let dir: WalletStore.ClosePayDirection = (proxyWho == "ta") ? .ta : .mine
        let paid = wallet.proxyPay(dir, amount: value, reason: "")
        guard paid > 0 else {
            let left = (dir == .mine) ? wallet.myBalance : wallet.taBalance
            let payer = (dir == .mine) ? "我" : Pronoun.current
            proxyNote = "\(payer)的钱包不够 \(WalletStore.money(value))（剩 \(WalletStore.money(left))）。"
            return
        }
        proxyNote = "已代付 \(WalletStore.money(paid))。"
        proxyAmountText = ""
    }

    // MARK: - 动作

    /// 5.20 显示成 "5.20"，52.00 显示成 "52"（整钱不拖两个零）。
    private static func shortMoney(_ value: Double) -> String {
        let whole = value.rounded()
        if abs(value - whole) < 0.005 { return String(format: "%.0f", whole) }
        return String(format: "%.2f", value)
    }

    private func send() {
        let cleaned = amountText.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else {
            note = "先填个金额（比如 5.20）。"
            return
        }
        let tail = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = wallet.send(amount: value, note: tail)
        guard sent > 0 else {
            note = "钱包里不够 \(WalletStore.money(value)) 了。"
            return
        }

        let info = ChatMessage.Transfer(amount: sent,
                                        note: tail,
                                        accepted: false,
                                        isRedPacket: isRedPacket)
        let id = chat.appendTransfer(info)

        // ⭐ 转账**当场生效、当场收工**：钱已经从「我」这边扣掉、气泡也落地了。
        //    「ta收不收」是ta的反应，跟转账本身是两件事 —— 让ta想一下再定，
        //    所以先回去（用户在聊天页等ta的回话，跟微信一样自然）。
        //
        // ⚠️ 以前这里是 `sleep(1.3s)` + `Double.random(in: 0..<1) < 0.85`：
        //    那个"ta在犹豫"是假的，而且**ta的人设完全不参与** ——
        //    你写「这是给你买药的钱」，ta照样有 15% 概率给你退回来。
        dismiss()

        Task { @MainActor in
            let decision = await Self.askHerAbout(sent, note: tail, isRedPacket: isRedPacket)
            guard decision.accept else {
                wallet.refund(sent)
                chat.markTransferDeclined(id)
                chat.append(ChatMessage(role: .assistant, text: decision.line))
                return
            }
            wallet.acceptIncoming(sent)
            chat.markTransferAccepted(id)
            chat.append(ChatMessage(role: .assistant, text: decision.line))
        }
    }

    // MARK: - ta的决定（收 / 不收）
    //
    // ⭐ 2026-10-01：让**ta自己**看一眼再定，而不是掷骰子。
    //    用户这次要的整句话是「能让 AI **真的**给内置的虚拟银行卡打钱」——
    //    「真的」两个字同样适用于"ta怎么回应"，不只是余额有没有动。
    //
    // ⚠️ 失败（没配 Key / 网络不通 / 输出看不懂）退回老办法。
    //    绝不能因为模型没答上，就让钱**卡在半路**（气泡一直挂着「待收款」）。

    private struct Decision {
        var accept: Bool
        var line: String
    }

    /// 问ta一句，让ta决定收不收、顺带回一句话。
    @MainActor
    private static func askHerAbout(_ amount: Double,
                                    note: String,
                                    isRedPacket: Bool) async -> Decision {
        let config = AppSettings.shared.llm
        let persona = PersonaStore.shared.persona
        guard persona.isComplete,
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rollDice()
        }

        let kind = isRedPacket ? "红包" : "转账"
        let noteText = note.isEmpty ? "（没写附言）" : note
        let instruction = """
        他刚刚在 App 里给你转了 \(WalletStore.money(amount)) 的\(kind)，附言：\(noteText)

        你要不要收？照你平时说话的方式回一句就行。

        ⚠️ 第一行只写「收」或者「不收」这两个字中的一个，别的什么都不要写。
        第二行起才是你想说的话，一两句，别太长。
        """

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: instruction)],
                // 让ta带着"纪念日 / 在一起多少天"看这件事 ——
                // 纪念日当天的转账和普通日子，ta的反应本来就该不一样。
                memory: CoupleStore.shared.injectedLines()
            ) {
                collected += piece
                if collected.count > 400 { break }
            }
        } catch {
            return rollDice()
        }

        // ⭐ 先剥掉末尾的心情标记再解析ta的答复 ——
        //    不然标记会被当成"ta想说的话"拼进那句里、露给用户。
        return parseDecision(MoodStore.shared.consume(collected)) ?? rollDice()
    }

    /// 认ta给的答复。**宽容**一点 —— ta不一定会老老实实守格式。
    private static func parseDecision(_ raw: String) -> Decision? {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let head = lines.first(where: { !$0.isEmpty }) else { return nil }

        let declines = head.contains("不收") || head.contains("不要")
            || head.contains("退回") || head.contains("算了")
        let accepts = head.hasPrefix("收") || head.contains("收下")
        // 第一行既不像收也不像不收 → 当没看懂，走兜底。
        guard declines || accepts else { return nil }

        let body = lines
            .drop { $0.isEmpty || $0 == head }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let defaultLine = declines
            ? declineLines.randomElement()!
            : acceptLines.randomElement()!
        return Decision(accept: !declines, line: body.isEmpty ? defaultLine : body)
    }

    /// 兜底：模型没答上来时用老办法（大概率收下）。
    private static func rollDice() -> Decision {
        if Double.random(in: 0..<1) < 0.85 {
            return Decision(accept: true, line: acceptLines.randomElement()!)
        }
        return Decision(accept: false, line: declineLines.randomElement()!)
    }

    /// ta收下时随口回的那句。
    private static let acceptLines = [
        "收到啦，谢谢～", "好呀，收下了", "谢谢宝贝！", "那我就不客气啦", "收到，爱你"
    ]
    /// ta不肯收、把钱退回来时说的那句。
    private static let declineLines = [
        "这个就不收啦，心意领了", "不用啦，你自己留着花", "哎呀，这次先不要啦", "退给你啦，别破费"
    ]
}

// MARK: - 聊天气泡

/// 聊天里那条转账 / 红包。微信那种带图标的卡片，不是普通气泡。
struct TransferBubble: View {
    let info: ChatMessage.Transfer
    let isMine: Bool
    var onTap: () -> Void

    private var tint: Color { info.isRedPacket ? Color(red: 0.90, green: 0.28, blue: 0.24) : Color.orange }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 36) }
            Button(action: onTap) { card }
                .buttonStyle(.plain)
            if !isMine { Spacer(minLength: 36) }
        }
    }

    private var card: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22))
                Image(systemName: info.isRedPacket ? "gift.fill" : "yensign.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.note.isEmpty ? (info.isRedPacket ? "恭喜发财" : "转账") : info.note)
                    .font(.aevis(13.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(transferStatus)
                    .font(.aevis(11))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            Spacer(minLength: 10)

            Text(WalletStore.money(info.amount))
                .font(.aevis(15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: 248, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    private var transferStatus: String {
        if info.declined { return "已退回" }
        if info.accepted { return "已收款" }
        return "待收款"
    }
}

// MARK: - 点开看详情

/// 点那条转账气泡进来的详情页。
struct TransferDetailSheet: View {

    let message: ChatMessage

    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @Environment(\.dismiss) private var dismiss

    private var info: ChatMessage.Transfer { message.transfer ?? .init(amount: 0) }
    private var isMine: Bool { message.role == .user }

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "ta" : name
    }

    private var detailStatus: String {
        if info.declined { return "已退回" }
        if info.accepted { return "已收款" }
        return "待收款"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22))
                    Image(systemName: info.isRedPacket ? "gift.fill" : "yensign.circle.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 68, height: 68)

                Text(WalletStore.money(info.amount))
                    .font(.aevis(30, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(isMine ? "转给\(personaName)" : "\(personaName)转给我")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)

                if !info.note.isEmpty {
                    Text(info.note)
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                Text(detailStatus)
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)

                // 别人转给我的、还没收 → 给个「收下」。
                // ⚠️ 只能是**ta的转账**：我自己转出去的没有"收下"这回事；
                //    已退回的也没有（钱早退回去了）。
                if !isMine, !info.accepted, !info.declined {
                    Button {
                        wallet.receive(amount: info.amount)
                        chat.markTransferAccepted(message.id)
                        dismiss()
                    } label: {
                        Text("收下")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .aevisGlass(cornerRadius: 15)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 30)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 34)
            .frame(maxWidth: .infinity)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle(info.isRedPacket ? "红包" : "转账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
