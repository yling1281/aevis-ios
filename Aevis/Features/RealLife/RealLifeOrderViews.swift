import SwiftUI
import Foundation

// 「真实生活」的**订单列表 / 订单详情 / 客服聊天**。
//
// ⚠️ 物流阶段**不缓存、不存盘** —— 一律 `store.stage(of:now:)` 现算。
//    外面的 `TimelineView`（在 `RealLifeView`）每 30 秒推着 `now` 往前走。

// MARK: - 时间

/// 订单时间的小格式化器（本文件私有）。
private enum RealLifeClock {
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func text(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - 付款方式文案

/// 把订单的付款方式翻成人话。
///
/// ⚠️ 不能直接用 `PaidBy.title` —— 它分不出亲密付 / 代付的**方向**
///    （`.closePay` / `.proxy` 的 `title` 都只有一个词）。方向存在 `order.payDirection`，
///    所以统一在这里映射；**别在别处再抄一遍这段 switch**。
private func paymentLabel(_ order: Order) -> String {
    switch order.paidBy {
    case .me:
        return "我付"
    case .closePay:
        if order.payDirection == "ta" { return "亲密付（ta 开的）" }
        if order.payDirection == "mine" { return "亲密付（我开的）" }
        return "亲密付"
    case .proxy:
        return "ta 代付"
    case .self_:
        return "\(Pronoun.current)自己付"
    }
}

// MARK: - 订单列表

struct OrderListView: View {

    let now: Date
    var onOpen: (Order) -> Void

    @ObservedObject private var store = RealLifeStore.shared

    private var orders: [Order] { store.orders() }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if orders.isEmpty {
                    emptyState
                } else {
                    ForEach(orders) { order in
                        OrderRow(order: order, now: now) { onOpen(order) }
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
            Text("📦")
                .font(.aevis(34))
            Text("还没有订单")
                .font(.aevis(14, weight: .medium))
                .foregroundStyle(.primary)
            Text("逛到喜欢的，下一单试试")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

/// 一行订单：店名 + 合计 + 下单时间 + 当前阶段 + 进度条。
struct OrderRow: View {

    let order: Order
    let now: Date
    var onOpen: () -> Void

    @ObservedObject private var store = RealLifeStore.shared
    @ObservedObject private var settings = AppSettings.shared

    private var accent: Color { settings.accentColor }

    private var shop: Shop? { store.shop(id: order.shopID) }
    private var stage: OrderStage { store.stage(of: order, now: now) }
    /// 配送费：**优先用订单里的快照**，老订单没有快照才退回按店铺现查。
    private var fee: Double { order.deliveryFee ?? shop?.deliveryFee ?? 0 }
    private var payable: Double { order.total + fee }

    private var stageColor: Color {
        (stage == .received || stage == .delivered) ? Color.green : accent
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(shop?.logo ?? "📦")
                        .font(.aevis(24))
                    Text(shop?.name ?? "店铺")
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(stage.title)
                        .font(.aevis(12, weight: .medium))
                        .foregroundStyle(stageColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(stageColor.opacity(0.14)))
                }

                StageProgress(kind: order.kind, stage: stage)

                HStack(spacing: 8) {
                    Text(RealLifeClock.text(order.createdAt))
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Text("合计 ¥" + RealLifeFormat.money(payable))
                        .font(.aevisMono(13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .aevisGlass(cornerRadius: 20)
    }
}

// MARK: - 进度条（横向节点）

/// 横向进度：按 `OrderStage.track(for:)` 铺节点，当前及之前的节点高亮。
struct StageProgress: View {

    let kind: RealLifeKind
    let stage: OrderStage

    @ObservedObject private var settings = AppSettings.shared
    private var accent: Color { settings.accentColor }

    private var track: [OrderStage] { OrderStage.track(for: kind) }
    private var currentIndex: Int { track.firstIndex(of: stage) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(track.indices, id: \.self) { index in
                let reached = index <= currentIndex
                Circle()
                    .fill(reached ? accent : Color.primary.opacity(0.12))
                    .frame(width: index == currentIndex ? 10 : 8,
                           height: index == currentIndex ? 10 : 8)

                if index < track.count - 1 {
                    Rectangle()
                        .fill(index < currentIndex ? accent : Color.primary.opacity(0.12))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

// MARK: - 订单详情

struct OrderDetailView: View {

    let orderID: UUID
    let now: Date

    @ObservedObject private var store = RealLifeStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var draft = ""

    private var accent: Color { settings.accentColor }

    private var order: Order? { store.allOrders.first { $0.id == orderID } }

    private var shop: Shop? {
        guard let order = order else { return nil }
        return store.shop(id: order.shopID)
    }

    var body: some View {
        Group {
            if let order = order, let shop = shop {
                content(order: order, shop: shop)
            } else {
                missingState
            }
        }
    }

    private func content(order: Order, shop: Shop) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                summaryCard(order: order, shop: shop)
                itemsCard(order: order, shop: shop)
                logisticsCard(order: order)
                chatCard(order: order)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            chatInput(order: order)
        }
    }

    private var missingState: some View {
        VStack(spacing: 8) {
            Text("🕳️").font(.aevis(30))
            Text("这笔订单找不到了").font(.aevis(13.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 概览

    private func summaryCard(order: Order, shop: Shop) -> some View {
        let stage = store.stage(of: order, now: now)
        let stageColor: Color = (stage == .received || stage == .delivered) ? Color.green : accent
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(shop.logo)
                    .font(.aevis(30))
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(shop.name)
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(order.addressHint.isEmpty ? "—" : order.addressHint)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(stage.title)
                    .font(.aevis(12, weight: .medium))
                    .foregroundStyle(stageColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(stageColor.opacity(0.14)))
            }

            StageProgress(kind: order.kind, stage: stage)

            HStack(spacing: 8) {
                Text("订单号 " + String(order.id.uuidString.prefix(8)))
                    .font(.aevisMono(11))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Text(RealLifeClock.text(order.createdAt))
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: 商品明细 + 金额

    private func itemsCard(order: Order, shop: Shop) -> some View {
        // 配送费优先用订单快照（老订单没有才退回店铺现查），合计一律 = 商品小计 + 这笔配送费。
        let fee = order.deliveryFee ?? shop.deliveryFee
        let payable = order.total + fee
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(order.items.indices, id: \.self) { index in
                let item = order.items[index]
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

            infoRow("商品合计", "¥" + RealLifeFormat.money(order.total))
            infoRow("配送费", "¥" + RealLifeFormat.money(fee))

            Divider()

            infoRow("实付", "¥" + RealLifeFormat.money(payable), emphasize: true)
            infoRow("付款方式", paymentLabel(order))
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func infoRow(_ title: String, _ value: String, emphasize: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.aevis(13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(emphasize ? .aevisMono(14.5, weight: .semibold) : .aevis(13))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: 物流时间线

    private func logisticsCard(order: Order) -> some View {
        let stage = store.stage(of: order, now: now)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox")
                    .font(.aevis(14))
                    .foregroundStyle(accent)
                Text("物流进度")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }

            StageTimeline(kind: order.kind, stage: stage)
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: 客服

    private func chatCard(order: Order) -> some View {
        let lines = store.chat(orderID: order.id)?.lines ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.aevis(14))
                    .foregroundStyle(accent)
                Text("联系客服")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }

            if lines.isEmpty {
                Text("有话想问，就在下面给店家发个消息吧。")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    bubble(line)
                }
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func bubble(_ line: ChatLine) -> some View {
        HStack {
            Text(line.text)
                .font(.aevis(13.5))
                .foregroundStyle(line.isMe ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(line.isMe ? accent : Color.primary.opacity(0.06))
                )
        }
        .frame(maxWidth: .infinity, alignment: line.isMe ? .trailing : .leading)
    }

    // MARK: 输入框（钉在底部）

    private func chatInput(order: Order) -> some View {
        HStack(spacing: 10) {
            TextField("给店家发条消息…", text: $draft)
                .font(.aevis(14))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .onSubmit { send(order: order) }

            Button {
                send(order: order)
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.aevis(14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(canSend ? accent : Color.secondary.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 发一条，稍后店家回一条当前阶段的话术。
    ///
    /// 这一页**只有你和店家**，所以这里没有任何指代 AI 的词。
    private func send(order: Order) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.appendChatLine(orderID: order.id, from: "me", text: text)
        draft = ""

        // 隔约 1 秒再回 —— 像店家真的在打字。
        let reply = store.scriptedLine(for: order, now: Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            store.appendChatLine(orderID: order.id, from: "shop", text: reply)
        }
    }
}

// MARK: - 物流时间线（纵向节点）

/// 纵向物流：每个 `track` 节点一行，走到的高亮。
struct StageTimeline: View {

    let kind: RealLifeKind
    let stage: OrderStage

    @ObservedObject private var settings = AppSettings.shared
    private var accent: Color { settings.accentColor }

    private var track: [OrderStage] { OrderStage.track(for: kind) }
    private var currentIndex: Int { track.firstIndex(of: stage) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(track.indices, id: \.self) { index in
                node(stage: track[index], index: index)
            }
        }
    }

    private func node(stage nodeStage: OrderStage, index: Int) -> some View {
        let reached = index <= currentIndex
        let isCurrent = index == currentIndex
        let isLast = index == track.count - 1
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(reached ? accent : Color.primary.opacity(0.12))
                    .frame(width: isCurrent ? 12 : 9, height: isCurrent ? 12 : 9)

                if !isLast {
                    Rectangle()
                        .fill(index < currentIndex ? accent.opacity(0.5) : Color.primary.opacity(0.12))
                        .frame(width: 2, height: 20)
                }
            }
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(nodeStage.title)
                    .font(.aevis(13.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(reached ? Color.primary : Color.secondary)
                if isCurrent {
                    Text("进行中")
                        .font(.aevis(10.5))
                        .foregroundStyle(accent)
                }
            }
            .padding(.top, isCurrent ? 0 : 1)

            Spacer(minLength: 8)
        }
    }
}
