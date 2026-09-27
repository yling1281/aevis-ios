import SwiftUI
import UIKit

/// 购买订单 —— 买家在购买页（`/buy`）下单之后的整条链路。
///
/// 流程：**下单** → 出订单号（让他付款时把订单号写在备注里）→ **他扫码付** →
/// 点「我已付款」→ 出现在这里、状态「待确认」→ 你核完账点「记已收款」→
/// **那一刻才发码**（解锁码 + 注册码，一起发到他留的邮箱）。
///
/// ⚠️ 支付宝到账监听做好之后，中间那步「点已收款」会**自动完成**
/// （监听认到备注里的订单号、且**金额对得上**才发）。
/// 这里留着是给"转账给你的、或者金额对不上"的情况兜底 —— 手动那条路永远要在。
struct OrdersSection: View {
    @EnvironmentObject private var store: AdminStore

    /// 正在确认的那一单。⚠️ 用订单号字符串而不是整条 `AdminOrder`：
    /// `.alert(item:)` 要 `Identifiable`，而订单号的 `id` 是 `String?`，
    /// nil 的时候身份判断会变得很微妙 —— 用字符串最省心。
    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "购买订单")
            if let stats = store.orderStats, !store.orders.isEmpty {
                summaryCard(stats)
            }
            if store.orders.isEmpty {
                AdminCard {
                    AdminEmpty(text: store.loading
                               ? "读取中…"
                               : "还没有订单。买家在购买页下单后，这里就会出现。")
                }
            } else {
                AdminCard {
                    ForEach(Array(store.orders.enumerated()), id: \.offset) { index, order in
                        row(order, divider: index > 0)
                    }
                }
            }
            AdminNote(text: "「记已收款」按下去就发码，钱没到别点。"
                     + "（解锁码 + 注册码一起发到他留的邮箱，这里也会显示那两串，"
                     + "可以直接复制发给他。）")
        }
        // ⚠️ 确认弹窗**不能省**：点一下就把码发出去且收不回来，
        //    网页那边也是先 confirm 再发（见 admin.html 的 btn-paid 那段）。
        .alert("确认收到这单的钱了？", isPresented: confirmingBinding) {
            Button("取消", role: .cancel) { confirming = nil }
            Button("确认，发码") {
                guard let id = confirming else { return }
                confirming = nil
                Task { await store.markOrderPaid(id) }
            }
        } message: {
            Text("按「确认」= 立刻给他发【解锁码 + 注册码】。\n订单：\(confirming ?? "")")
        }
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: { confirming != nil },
            set: { if !$0 { confirming = nil } }
        )
    }

    private func summaryCard(_ stats: AdminOrderStats) -> some View {
        AdminCard {
            HStack(spacing: 0) {
                AdminStatCell(label: "订单总数", value: stats.total)
                AdminStatCell(label: "已收款", value: stats.paid)
                AdminStatCell(label: "等你确认", value: stats.waiting)
            }
        }
    }

    private func row(_ order: AdminOrder, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: order.id ?? "—",
                subtitle: (order.contact ?? "?")
                    + "　·　" + (order.amount?.shown ?? "?") + " 元"
                    + "　·　" + AdminFormat.when(order.createdAt),
                detail: detailText(order),
                badge: order.isPaid ? ("已收款", AdminSkin.warn) : ("待确认", AdminSkin.brand)
            )
        } trailing: {
            if order.isPaid {
                if let code = order.unlockCode, !code.isEmpty {
                    AdminCopyButton(text: code, label: "复制解锁码")
                }
            } else {
                AdminMiniButton(title: "记已收款", tint: AdminSkin.brand, filled: true) {
                    confirming = order.id
                }
            }
        }
    }

    /// 卡片里那几行小字：付款备注 + 发了哪两张码。
    private func detailText(_ order: AdminOrder) -> String {
        var lines: [String] = []
        if let note = order.paidNote, !note.isEmpty { lines.append(note) }
        if order.isPaid {
            let unlock = order.unlockCode ?? "—"
            let invite = order.inviteCode ?? "—"
            let mail = order.mailSent ? "（邮件已发）" : "（⚠️ 邮件没发出去，手动发给他）"
            lines.append("解锁码 \(unlock) · 注册码 \(invite) \(mail)")
            if let at = order.paidAt, at > 0 {
                lines.append("确认于 " + AdminFormat.when(at)
                             + (order.paidBy?.isEmpty == false ? "　·　\(order.paidBy!)" : ""))
            }
        } else {
            lines.append("还没发码（等你确认收款）")
        }
        return lines.joined(separator: "\n")
    }
}
