import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「积分」页：余额 / 充值 / 兑换 / 记录。
///
/// 2026-10-31 新增。用户要求：
/// 「目前只有会员充值，需要补做积分充值功能，本次一并实现，兑换比例为 1 元 = 200 积分」。
///
/// 三条硬约束（都是踩过的坑）：
///  ① **比例只在服务端算**，这里显示后端给的 `points`，绝不自己乘 200；
///  ② 支付**不在 App 内完成**（iOS 没有网页收银台容器，`WKWebView` 里跳第三方支付会被拦），
///     所以走"系统浏览器打开收银台 → 回来点『我已完成支付』核对"这条路；
///  ③ 核对结果**如实显示**：pending 就说还没到账，绝不因为"用户点了一下"就假装到账。
struct PointsView: View {
    @ObservedObject private var service = PointsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tab: Tab = .recharge
    @State private var busyID: String?
    @State private var note: String?
    @State private var noteIsBad = false

    enum Tab: String, CaseIterable, Identifiable {
        case recharge, shop, records
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recharge: return "充值"
            case .shop: return "兑换"
            case .records: return "记录"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    balanceCard
                    if service.pending != nil { pendingCard }
                    switcher

                    switch tab {
                    case .recharge: rechargeSection
                    case .shop: shopSection
                    case .records: recordsSection
                    }

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(noteIsBad ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .navigationTitle("积分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .refreshable { await service.refresh() }
            .task { await service.refresh() }
        }
    }

    // MARK: - 余额

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("我的积分")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(service.points)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("积分")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
            }
            Text("≈ ￥\(service.yuan)　·　\(service.rate)")
                .font(.aevis(12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 待支付

    @ViewBuilder
    private var pendingCard: some View {
        if let p = service.pending {
            VStack(alignment: .leading, spacing: 8) {
                Text("待支付 · ￥\(p.amountYuan) → \(p.points) 积分")
                    .font(.aevis(14, weight: .semibold))
                Text("订单号 \(p.orderNo)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button {
                        openPayURL(p.payURL)
                    } label: {
                        Text("打开收银台").font(.aevis(13, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        checkPaid()
                    } label: {
                        Text("我已完成支付").font(.aevis(13))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("关闭") { service.clearPending() }
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                }
                Text("iOS 不允许 App 内完成第三方支付：请在浏览器里付完再回来核对。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppSettings.shared.accentColor.opacity(0.10)))
        }
    }

    private var switcher: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { tab = item }
                } label: {
                    Text(item.label)
                        .font(.aevis(13, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(tab == item ? 0.10 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 充值

    private var rechargeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if service.refreshing && service.packages.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if service.packages.isEmpty {
                emptyText("暂时没有可用的充值包。")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(service.packages) { pkg in
                        Button {
                            buy(pkg)
                        } label: {
                            VStack(spacing: 3) {
                                Text("\(pkg.points)")
                                    .font(.aevis(19, weight: .semibold))
                                    .monospacedDigit()
                                Text("积分").font(.aevis(11)).foregroundStyle(.secondary)
                                Text("￥\(pkg.amountYuan)")
                                    .font(.aevis(13, weight: .semibold))
                                    .foregroundStyle(AppSettings.shared.accentColor)
                                    .padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08)))
                            .opacity(service.payEnabled ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .disabled(busyID != nil)
                    }
                }
                Text(service.payEnabled
                     ? "1 元 = 200 积分。到账后可在「兑换」里换会员。"
                     : "在线支付还没开通，可先用卡密或联系客服充值。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = service.error {
                Text(err).font(.aevis(12)).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 兑换

    private var shopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if service.items.isEmpty {
                emptyText("暂时没有可兑换的商品。")
            } else {
                ForEach(service.items) { item in
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.aevis(15, weight: .medium))
                            if !item.note.isEmpty {
                                Text(item.note).font(.aevis(11.5)).foregroundStyle(.secondary)
                            }
                            Text("\(item.cost) 积分")
                                .font(.aevis(12.5, weight: .semibold))
                                .foregroundStyle(AppSettings.shared.accentColor)
                        }
                        Spacer(minLength: 0)
                        Button {
                            redeem(item)
                        } label: {
                            Text(item.soldOut ? "已兑完" : (busyID == item.code ? "兑换中" : "兑换"))
                                .font(.aevis(13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(item.soldOut || busyID != nil)
                    }
                    .padding(13)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.05)))
                }
            }
        }
    }

    // MARK: - 记录

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !service.recharges.isEmpty {
                Text("充值记录").font(.aevis(13, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(service.recharges) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("+\(r.points) 积分").font(.aevis(14, weight: .medium))
                            Text(r.paidAt.isEmpty ? r.createdAt : r.paidAt)
                                .font(.aevis(11)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("￥\(r.amountYuan)").font(.aevis(13)).monospacedDigit()
                            Text(stateText(r.state))
                                .font(.aevis(11))
                                .foregroundStyle(r.state == "paid" ? Color.secondary : Color.orange)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04)))
                }
            }

            if !service.redeemOrders.isEmpty {
                Text("兑换记录").font(.aevis(13, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(service.redeemOrders) { o in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.itemName).font(.aevis(14))
                            Text(o.note.isEmpty ? o.createdAt : o.note)
                                .font(.aevis(11)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Text("-\(o.cost)").font(.aevis(13)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04)))
                }
            }

            if service.recharges.isEmpty && service.redeemOrders.isEmpty {
                emptyText("还没有记录。")
            }
        }
    }

    private func stateText(_ s: String) -> String {
        switch s {
        case "paid": return "已到账"
        case "pending": return "待支付"
        case "refunded": return "已退款"
        default: return s
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }

    // MARK: - 动作

    private func buy(_ pkg: PointsService.Package) {
        guard service.payEnabled else {
            say("在线支付还没开通，先用卡密或联系客服吧。", bad: true)
            return
        }
        busyID = pkg.code
        note = nil
        Task {
            defer { busyID = nil }
            do {
                let p = try await service.createRecharge(package: pkg.code)
                if p.payURL.isEmpty {
                    say("下单成功，但没拿到收银台地址，请联系客服并提供订单号 \(p.orderNo)", bad: true)
                    return
                }
                openPayURL(p.payURL)
                say("已打开收银台。付完回来点「我已完成支付」。", bad: false)
            } catch {
                say(error.localizedDescription, bad: true)
            }
        }
    }

    private func checkPaid() {
        Task {
            do {
                if let got = try await service.checkPending() {
                    say(got > 0 ? "已到账 \(got) 积分" : "这笔已退款", bad: false)
                } else {
                    say("服务端还没收到支付回调。付完请等 1 分钟再点一次；"
                        + "一直不到账就把订单号发给客服。", bad: true)
                }
            } catch {
                say(error.localizedDescription, bad: true)
            }
        }
    }

    private func redeem(_ item: PointsService.ShopItem) {
        guard service.points >= item.cost else {
            say("积分不够：需要 \(item.cost)，你还有 \(service.points)。先充值。", bad: true)
            tab = .recharge
            return
        }
        busyID = item.code
        note = nil
        Task {
            defer { busyID = nil }
            do {
                let msg = try await service.redeem(item)
                say(msg, bad: false)
            } catch {
                say(error.localizedDescription, bad: true)
            }
        }
    }

    private func say(_ text: String, bad: Bool) {
        note = text
        noteIsBad = bad
    }

    private func openPayURL(_ raw: String) {
        #if canImport(UIKit)
        guard let url = URL(string: raw) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}
