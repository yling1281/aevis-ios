import SwiftUI
import UIKit

/// 支付宝收款流水 —— 服务器上那个监听（`alipay_watch.py`）抓到的东西。
///
/// ⚠️ **这里只读**：数据是监听服务每 150 秒去支付宝拉一次、写进 `alipay_trades` 的
/// （被风控时会自动放慢到最多 15 分钟一次），管理端不做任何写入。
///
/// ⚠️ **转账 / 红包不在这张表里**：只有走**收款码**的钱才算"一笔交易"。
/// 用户要是用"转账"给你的，监听根本看不到 —— 对账时别只看这一页。
struct PaymentsSection: View {
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "支付宝收款")
            if let stats = store.paymentStats, !store.payments.isEmpty {
                summaryCard(stats)
            }
            AdminFold("收款明细", key: "section.payments", count: store.payments.count) {
                if store.payments.isEmpty {
                    AdminCard {
                        AdminEmpty(text: store.loading
                                   ? "读取中…"
                                   : "还没抓到收款记录。监听每 150 秒看一次，刚开的话等一会儿。")
                    }
                } else {
                    AdminCard {
                        ForEach(Array(store.payments.enumerated()), id: \.offset) { index, pay in
                            row(pay, divider: index > 0)
                        }
                    }
                }
            }
            AdminNote(text: "数据来自服务器上的收款监听，只读。"
                     + "备注里带着订单号的，就是「照订单付的」那一笔。"
                     + "⚠️ 转账/红包不会出现在这里（只有收款码的钱才算交易），"
                     + "对账时留意。")
        }
    }

    private func summaryCard(_ stats: AdminPaymentStats) -> some View {
        AdminCard {
            HStack(spacing: 0) {
                AdminStatCell(label: "抓到笔数", value: stats.total)
                AdminStatCell(label: "对得上订单", value: stats.mapped)
                VStack(alignment: .leading, spacing: 4) {
                    Text(money(stats.amount))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("合计（元）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private func row(_ pay: AdminPayment, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: (pay.amount?.shown ?? "—") + " 元",
                subtitle: [pay.paidAt, pay.direction, pay.status]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                detail: "备注：" + (pay.memo?.isEmpty == false ? pay.memo! : "（没写）")
                    + "　买家：" + (pay.buyer?.isEmpty == false ? pay.buyer! : "—")
                    + (pay.goods?.isEmpty == false ? "\n来自：\(pay.goods!)" : ""),
                badge: pay.isMapped ? ("对上了 \(pay.orderId!)", AdminSkin.brand) : nil
            )
        } trailing: {
            if pay.isMapped, let code = pay.orderId {
                AdminCopyButton(text: code, label: "复制单号")
            }
        }
    }

    /// `0.04` → `0.04`；`12.0` → `12.00`。金额一律两位小数，免得看着像少了一分钱。
    private func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}
