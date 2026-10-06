import SwiftUI

// 「发现页 → 真实生活」的界面。
//
// 这一页**自己不带 NavigationStack 外壳** —— 它是从发现页 present 出来的，
// 上层已经给出了导航上下文。页内的跳转（店列表 → 商品页 → 订单详情）
// 用**一个 `@State` 的 Route 枚举**自己切，回到根就设成 `.root`。
//
// 🔴 物流是**随时钟自己往前走**的（数据层是纯函数现算，绝不存阶段）。
//    所以整页套了一层 `TimelineView(.periodic(by: 30))`，每 30 秒重算一次 ——
//    用户停在页面上就能肉眼看到进度往前推。
//
// ⚠️ 文案口径：这一页是「你自己在逛店 / 点外卖」，正经文案里**不出现指代 AI 的词**；
//    万一要指代，一律用 `\(Pronoun.current)`，**不许写死性别代词**。

struct RealLifeView: View {

    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    /// 顶部三个分段：两个世界 + 订单列表。
    @State private var section: Section = .shopping

    /// 页内跳转。**不用 NavigationStack** —— 这一页是从发现页 present 出来的。
    @State private var route: Route = .root

    // MARK: - 分段 / 路由

    /// 顶部 `Picker` 的三个分段。
    enum Section: String, CaseIterable, Identifiable {
        case shopping
        case food
        case orders

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shopping: return "购物"
            case .food: return "外卖"
            case .orders: return "订单"
            }
        }
    }

    /// 页内跳转目的地。
    enum Route: Equatable {
        case root
        case goods(String)     // 商品页：店的 id
        case order(UUID)       // 订单详情：订单 id
    }

    private var accent: Color { settings.accentColor }

    // MARK: - Body

    var body: some View {
        // 每 30 秒重算一次：物流是随时钟自己走的，停在页面上要能看见进度推进。
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .aevisScreen("真实生活")
    }

    private func content(now: Date) -> some View {
        ZStack {
            AevisBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                header

                switch route {
                case .root:
                    rootContent(now: now)
                case .goods(let shopID):
                    GoodsView(shopID: shopID, now: now) { order in
                        open(.order(order.id))
                    }
                case .order(let orderID):
                    OrderDetailView(orderID: orderID, now: now)
                }
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if route == .root {
                    Text("真实生活")
                        .font(.aevis(20, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Button {
                        open(.root)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.aevis(14, weight: .semibold))
                            Text("返回")
                                .font(.aevis(15))
                        }
                        .foregroundStyle(accent)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .aevisGlass(cornerRadius: 10)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if route == .root {
                Picker("", selection: $section) {
                    ForEach(Section.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 根视图（店列表 / 订单列表）

    @ViewBuilder
    private func rootContent(now: Date) -> some View {
        switch section {
        case .shopping:
            ShopListView(kind: .shopping, now: now) { shop in
                open(.goods(shop.id))
            }
        case .food:
            ShopListView(kind: .food, now: now) { shop in
                open(.goods(shop.id))
            }
        case .orders:
            OrderListView(now: now) { order in
                open(.order(order.id))
            }
        }
    }

    // MARK: - 动作

    private func open(_ destination: Route) {
        withAnimation(.snappy(duration: 0.24)) {
            route = destination
        }
    }
}
