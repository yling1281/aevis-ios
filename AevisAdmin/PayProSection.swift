import SwiftUI

/// PayPro 收款 —— 用户买的那套收款系统（`/pay/`）里的订单，**只读**。
///
/// 数据由我们后端去登录 PayPro 拉回来（见 `app.py` 的 `api_admin_paypro`），
/// 浏览器 / 管理端里都没有 PayPro 的密码。「放行 / 驳回」还是去原后台点
/// （网页后台里那个「展开 PayPro 原后台」按钮）。
struct PayProSection: View {
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "PayPro 收款")
            if let stats = store.payproStats, !store.payproOrders.isEmpty {
                summaryCard(stats)
            }
            AdminFold("PayPro 订单", key: "section.paypro", count: store.payproOrders.count) {
                if let unavailable = store.payproUnavailable {
                    AdminCard {
                        AdminEmpty(text: "PayPro 暂时连不上：" + unavailable)
                    }
                } else if store.payproOrders.isEmpty {
                    AdminCard {
                        AdminEmpty(text: store.loading
                                   ? "读取中…"
                                   : "PayPro 里还没有订单。官网付款切过去之后才会流进来。")
                    }
                } else {
                    AdminCard {
                        ForEach(Array(store.payproOrders.enumerated()), id: \.offset) { index, order in
                            row(order, divider: index > 0)
                        }
                    }
                }
            }
            AdminNote(text: "这是「PayPro」里收到的订单（官网付款走的就是它）。"
                     + "买家付款后，在网页后台或邮件里点「通过」才会自动发码。"
                     + "这里只读；放行/驳回去原后台点。")
        }
    }

    private func summaryCard(_ stats: AdminPayProStats) -> some View {
        AdminCard {
            HStack(spacing: 0) {
                AdminStatCell(label: "订单总数", value: stats.total)
                AdminStatCell(label: "已支付", value: stats.paid)
                AdminStatCell(label: "待支付", value: stats.unpaid)
            }
        }
    }

    private func row(_ order: AdminPayProOrder, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: (order.amount ?? "—") + " 元",
                subtitle: [order.payTypeLabel, order.stateText, order.createdAt]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                detail: "买家：" + (order.email?.isEmpty == false ? order.email! : "—")
                    + (order.nickname?.isEmpty == false ? "（\(order.nickname!)）" : "")
                    + "　付款号：" + (order.payNum?.isEmpty == false ? order.payNum! : "—"),
                badge: order.state == 1 ? ("已支付", AdminSkin.brand) : nil
            )
        } trailing: {
            if let code = order.id, !code.isEmpty {
                AdminCopyButton(text: code, label: "复制单号")
            }
        }
    }
}
