import SwiftUI
import Foundation

// 「真实生活」的**逛店 / 商品 / 结算**这几屏。
// 主入口在 `RealLifeView.swift`，订单相关在 `RealLifeOrderViews.swift`。

// MARK: - 格式化

/// 价格 / 销量 / 送达时间的统一口径 —— 数字都走 `aevisMono`，价格一律 `¥%.2f`。
enum RealLifeFormat {

    /// 价格：统一两位小数。
    static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// 月售 / 销量：过万就折成「x.x万」。
    static func sales(_ value: Int) -> String {
        if value >= 10000 {
            return String(format: "%.1f万", Double(value) / 10000.0)
        }
        return "\(value)"
    }

    /// 送达时间：购物按小时 / 天，外卖按分钟。
    static func eta(_ minutes: Int, kind: RealLifeKind) -> String {
        if kind == .shopping {
            if minutes >= 1440 {
                return String(format: "预计 %.1f 天送达", Double(minutes) / 1440.0)
            }
            let hours = max(1, minutes / 60)
            return "预计 \(hours) 小时送达"
        }
        return "预计 \(minutes) 分钟送达"
    }

    /// 配送费文案。
    static func delivery(_ shop: Shop) -> String {
        if shop.deliveryFee <= 0 {
            return shop.kind == .shopping ? "包邮" : "免配送费"
        }
        return "配送费 ¥" + money(shop.deliveryFee)
    }

    /// 订单「应付」= 商品小计（`order.total`）+ 配送费。
    ///
    /// 数据层的 `placeOrder` 只把**商品小计**写进 `order.total`（冻结口径，不许改），
    /// 配送费不落盘；这里按 `shop.deliveryFee` **现取后加**，
    /// 保证「结算页看到的应付」和「订单页显示的合计」是**同一个数**。
    static func payable(_ total: Double, deliveryFee: Double) -> Double {
        ((total + deliveryFee) * 100).rounded() / 100
    }
}

// MARK: - 店列表

/// 某个场景下的店列表（购物 或 外卖）。
struct ShopListView: View {

    let kind: RealLifeKind
    let now: Date
    var onOpen: (Shop) -> Void

    @ObservedObject private var store = RealLifeStore.shared

    private var shops: [Shop] { store.shops(kind: kind) }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if shops.isEmpty {
                    emptyState
                } else {
                    ForEach(shops) { shop in
                        ShopRow(shop: shop) { onOpen(shop) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(kind == .shopping ? "🛍️" : "🥡")
                .font(.aevis(34))
            Text(kind == .shopping ? "这里还没有店" : "附近还没有外卖")
                .font(.aevis(14, weight: .medium))
                .foregroundStyle(.primary)
            Text("稍后再来看看吧")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// 一行店。
struct ShopRow: View {

    let shop: Shop
    var onOpen: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    private var accent: Color { settings.accentColor }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Text(shop.logo)
                    .font(.aevis(30))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 5) {
                    Text(shop.name)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.aevis(10))
                            .foregroundStyle(Color.orange)
                        Text(String(format: "%.1f", shop.rating))
                            .font(.aevisMono(12, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("月售 " + RealLifeFormat.sales(shop.monthlySales))
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                    }

                    if !shop.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(shop.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.aevis(10))
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(accent.opacity(0.12))
                                    )
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Text(RealLifeFormat.delivery(shop))
                            .font(.aevis(11))
                            .foregroundStyle(.secondary)
                        Text("起送 ¥" + RealLifeFormat.money(shop.minOrder))
                            .font(.aevisMono(11))
                            .foregroundStyle(.secondary)
                        Text(RealLifeFormat.eta(shop.etaMinutes, kind: shop.kind))
                            .font(.aevis(11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .aevisGlass(cornerRadius: 20)
    }
}

// MARK: - 商品页

/// 一家店里的商品 / 菜。每行可 `+/-` 选数量；右下悬浮「去结算」。
struct GoodsView: View {

    let shopID: String
    let now: Date
    var onPlaced: (Order) -> Void

    @ObservedObject private var store = RealLifeStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var counts: [String: Int] = [:]
    @State private var showCheckout = false

    private var accent: Color { settings.accentColor }

    private var shop: Shop? { store.shop(id: shopID) }
    private var goods: [Goods] { store.goods(shopID: shopID) }

    /// 已选的行（只保留数量 > 0 的）。
    private var items: [OrderItem] {
        goods.compactMap { good in
            let count = counts[good.id] ?? 0
            guard count > 0 else { return nil }
            return OrderItem(name: good.name, price: good.price, count: count)
        }
    }

    private var subtotal: Double {
        items.reduce(0) { $0 + $1.subtotal }
    }

    private var totalCount: Int {
        items.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 12) {
                    if let shop {
                        shopHeader(shop)
                    }
                    ForEach(goods) { good in
                        goodsRow(good)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)

            checkoutButton
                .padding(.trailing, 16)
                .padding(.bottom, 18)
        }
        .sheet(isPresented: $showCheckout) {
            if let shop {
                CheckoutSheet(shop: shop, items: items) { order in
                    showCheckout = false
                    onPlaced(order)
                }
            }
        }
    }

    // MARK: 店头

    private func shopHeader(_ shop: Shop) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(shop.logo)
                    .font(.aevis(34))
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.name)
                        .font(.aevis(16, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.aevis(10))
                            .foregroundStyle(Color.orange)
                        Text(String(format: "%.1f", shop.rating))
                            .font(.aevisMono(12, weight: .medium))
                        Text("月售 " + RealLifeFormat.sales(shop.monthlySales))
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                Text(RealLifeFormat.delivery(shop))
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                Text("起送 ¥" + RealLifeFormat.money(shop.minOrder))
                    .font(.aevisMono(11.5))
                    .foregroundStyle(.secondary)
                Text(RealLifeFormat.eta(shop.etaMinutes, kind: shop.kind))
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: 一行商品

    private func goodsRow(_ good: Goods) -> some View {
        let count = counts[good.id] ?? 0
        return HStack(spacing: 12) {
            Text(good.icon)
                .font(.aevis(30))
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(good.name)
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(good.desc)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("¥" + RealLifeFormat.money(good.price))
                        .font(.aevisMono(14, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("已售 " + RealLifeFormat.sales(good.sales))
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            stepper(good, count: count)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .aevisGlass(cornerRadius: 18)
    }

    @ViewBuilder
    private func stepper(_ good: Goods, count: Int) -> some View {
        HStack(spacing: 10) {
            if count <= 0 {
                Button {
                    setCount(good, 1)
                } label: {
                    plusBadge
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    setCount(good, count - 1)
                } label: {
                    minusBadge
                }
                .buttonStyle(.plain)

                Text("\(count)")
                    .font(.aevisMono(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 20)

                Button {
                    setCount(good, count + 1)
                } label: {
                    plusBadge
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var plusBadge: some View {
        Image(systemName: "plus")
            .font(.aevis(13, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(accent))
    }

    private var minusBadge: some View {
        Image(systemName: "minus")
            .font(.aevis(13, weight: .bold))
            .foregroundStyle(accent)
            .frame(width: 28, height: 28)
            .overlay(Circle().strokeBorder(accent.opacity(0.7), lineWidth: 1.2))
    }

    // MARK: 悬浮「去结算」

    private var checkoutButton: some View {
        Button {
            guard totalCount > 0 else { return }
            showCheckout = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "cart.fill")
                    .font(.aevis(14, weight: .semibold))
                Text(totalCount > 0
                     ? "去结算 · \(totalCount) 件 · ¥" + RealLifeFormat.money(subtotal)
                     : "去结算")
                    .font(.aevis(14.5, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(totalCount > 0 ? accent : Color.secondary.opacity(0.5))
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(totalCount == 0)
    }

    private func setCount(_ good: Goods, _ value: Int) {
        let clamped = max(0, value)
        if clamped == 0 {
            counts.removeValue(forKey: good.id)
        } else {
            counts[good.id] = clamped
        }
    }
}
