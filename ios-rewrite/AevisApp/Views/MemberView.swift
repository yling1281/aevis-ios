import SwiftUI
import UIKit

/// 会员独立页（2026-11-23 从 `ShopView` 迁出）：只承载「套餐」。
///
/// - 四档现价来自 `ShopProduct.priceCents`（1490/2190/4490/8790 分），一律 `specifier:"%.1f"`，
///   否则 14.9 会被 `%.0f` 吞成 "¥15"；划线原价 `origPriceValue` 用 `¥%.1f`（16.9/24.9/49.9/97.9）。
/// - 九折弹窗：**每天第一次进会员页弹一次**（`aevisMemberDiscountLastShownDate` 存本地 yyyy-MM-dd，
///   跨天自动重置、同日不重复、可关闭）；页面常驻「限时九折」入口可再次手动查看。
///   强制更新逻辑（AppUpdate/UpdateSheet）完全不碰。
/// - `memberDays <= 0` 时顶部「当前方案」整块不渲染（不是显示「未开通」）。
/// - 支付流程自成一套（复用 `PayQRView` / `PaySuccessView`），与商城墨点支付互不干扰。
/// - 夜间配色收敛到 `AE` 会员语义色（`Color.adaptive`），浅色保持原值。
struct MemberView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    @State private var products: [APIClient.ShopProduct] = []
    @State private var memberDays: Int? = nil
    @State private var selectedProduct: APIClient.ShopProduct? = nil
    @State private var tip = ""

    /// 九折弹窗日期键：yyyy-MM-dd（本地日历）。空串 = 从未弹过。
    @AppStorage("aevisMemberDiscountLastShownDate") private var lastShownDate: String = ""
    @State private var showDiscount = false

    // 支付流程状态（与商城页各自持有一套）
    private enum PayChannel: String { case alipay, wxpay }
    private struct ActivePay {
        let order: APIClient.PayOrder
        let title: String
    }
    @State private var showChannelPicker = false
    @State private var activePay: ActivePay? = nil
    @State private var showWeChatQR = false
    @State private var showAlipayConfirm = false
    @State private var showSuccess = false
    @State private var successResult: APIClient.PayVerifyResult? = nil
    @State private var alipayConfirming = false

    /// 会员权益（2026-11-24 产品文案先上 UI）。后端 `/v1/shop/products` 目前只有
    /// id/title/days/price_cents/week_total/percent/label，**没有结构化权益字段**；
    /// 这里先按用户口述列出，需后端补 `benefits[]` / `signin_bonus` / `free_minutes` 后再改成动态读取。
    private let benefitItems = [
        "开通立得墨点",
        "月卡 · 固定 30 天",
        "本周用量一次回满",
        "每天签到翻倍",
        "免费时长",
    ]

    /// 后端 `/v1/shop/products` 已下发 `benefits[]`（字符串数组），优先用服务端文案；
    /// 老服务端缺字段时回落本地占位，不让权益区空白。
    private var displayedBenefits: [String] {
        let list = selectedProduct?.benefits.isEmpty == false
            ? selectedProduct?.benefits
            : products.first?.benefits
        return (list?.isEmpty == false) ? list! : benefitItems
    }

    /// 本地日期（yyyy-MM-dd），用于九折键；POSIX locale 只为固定格式，时区仍用本地。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var todayString: String { Self.dayFormatter.string(from: Date()) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("会员").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Spacer()
                // 常驻入口：同日已弹过仍可手动查看九折详情
                Button { showDiscount = true } label: {
                    Text("限时九折")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AE.memberBadge)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AE.memberBadge.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            ZStack {
                memberTab
                    .clipped()   // 防档位卡 spring 越界留残影
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .background(AppBackground())
        .navigationTitle("会员")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showDiscount) { discountSheet }
        .sheet(isPresented: $showChannelPicker) { channelPicker }
        .sheet(isPresented: $showWeChatQR) { weChatQRSheet }
        .sheet(isPresented: $showAlipayConfirm) { alipayConfirmSheet }
        .sheet(isPresented: $showSuccess) { successSheet }
    }

    // MARK: - 九折弹窗（每日首次进页）

    private func shouldShowDiscount() -> Bool {
        lastShownDate != todayString
    }

    private func markDiscountShown() {
        lastShownDate = todayString
    }

    /// 只在真的弹出来时才写日期键，保证「同日不重复」且不会因为加载失败白白消耗一次。
    private func maybeShowDailyDiscount() {
        guard !products.isEmpty, shouldShowDiscount() else { return }
        showDiscount = true
        markDiscountShown()
    }

    private var discountProduct: APIClient.ShopProduct? {
        selectedProduct ?? products.first
    }

    private var discountSheet: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AE.memberBadge.opacity(0.16)).frame(width: 60, height: 60)
                Image(systemName: "gift.fill").font(.system(size: 26)).foregroundStyle(AE.memberBadge)
            }
            Text("限时九折")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(AE.memberAccent)
            if let p = discountProduct {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    AnimatedNumber(
                        value: origPriceValue(p.priceCents), specifier: "¥%.1f",
                        font: .system(size: 14), color: AE.textSecondary
                    )
                    .overlay(alignment: .center) { strikeLine }
                    AnimatedNumber(
                        value: Double(p.priceCents) / 100, specifier: "¥%.1f",
                        font: .system(size: 30, weight: .heavy, design: .rounded), color: AE.memberAccent
                    )
                    Text("/月").font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                }
                Text("\(p.label.isEmpty ? "套餐" : p.label) · 固定 \(p.days) 天")
                    .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
            }
            Text("划线原价 ¥\(discountProduct.map { String(format: "%.1f", origPriceValue($0.priceCents)) } ?? "—")，现价为原价九折。每天首次进入会员页提醒一次。")
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showDiscount = false
            } label: {
                Text("知道了")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(AE.accentDeep, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .presentationDetents([.medium])
        .glassSheetBackground()
    }

    // MARK: - 加载

    private func load() async {
        async let s = APIClient.shopProducts()
        async let days = APIClient.membershipDays(token: session.token ?? "")
        let prods = (try? await s) ?? []
        let mDays = (try? await days)
        await MainActor.run {
            products = prods
            memberDays = mDays
            if selectedProduct == nil { selectedProduct = prods.first }
            maybeShowDailyDiscount()
        }
    }

    // MARK: - 套餐列表

    private var memberTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // 先给免费用量基线，让用户知道不开套餐也有约 15 条/周
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(AE.brandPurple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("免费用量基线")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AE.textPrimary)
                        Text("不开套餐也有约 \(APIClient.freeMessageBaseline) 条消息 / 周")
                            .font(.system(size: 11))
                            .foregroundStyle(AE.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(13)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.14)

                // R2.7：未开通（nil 或 <=0）时整块「当前方案」不渲染
                if let d = memberDays, d > 0 {
                    HStack(spacing: 12) {
                        AevisMascot(size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("当前方案").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                            AnimatedNumber(value: d, font: .system(size: 19, weight: .bold, design: .rounded), suffix: " 天")
                                .foregroundStyle(AE.textPrimary)
                            Text("固定 30 天 · 每周一刷新额度")
                                .font(.system(size: 11.5)).foregroundStyle(AE.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 15)
                    .padding(.vertical, 13)
                    .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.18)
                    .shadow(color: AE.shadowColor, radius: 8, y: 3)
                }

                // 会员权益清单（后端字段待补，当前按产品文案展示）
                VStack(alignment: .leading, spacing: 8) {
                    Text("会员权益")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AE.textSecondary)
                    ForEach(displayedBenefits, id: \.self) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(AE.brandPurple)
                            Text(item)
                                .font(.system(size: 12.5))
                                .foregroundStyle(AE.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.14)

                Text("用量越多越划算 · 固定 30 天 · 每周一刷新额度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AE.brandPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 1)

                ForEach(products) { prod in memberCell(prod) }
                if products.isEmpty {
                    Text("套餐加载中或暂不可用")
                        .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }

                // 选中档位的用量/倍数：数字用 AnimatedNumber 翻动，与档位名 spring 联动
                if let p = selectedProduct {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(p.label.isEmpty ? "套餐" : p.label) 用量")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                            .animation(.spring(response: 0.32, dampingFraction: 0.82),
                                       value: selectedProduct?.id)
                        AnimatedNumber(
                            value: p.percent,
                            font: .system(size: 18, weight: .bold, design: .rounded),
                            color: AE.memberAccent, suffix: "%"
                        )
                        Text("· 基础用量的 ")
                            .font(.system(size: 11.5)).foregroundStyle(AE.textSecondary)
                        AnimatedNumber(
                            value: Double(p.percent) / 100.0, specifier: "%.1f",
                            font: .system(size: 12.5, weight: .medium), color: AE.textSecondary
                        )
                        Text(" 倍")
                            .font(.system(size: 11.5)).foregroundStyle(AE.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassCard(cornerRadius: 14, material: .thin, tintOpacity: 0.12)
                }

                // 底部开通按钮：现价 %.1f 保住 .9 尾数，切档位时随 priceCents 联动
                payButton(enabled: selectedProduct != nil, action: { showChannelPicker = true }) {
                    HStack(spacing: 0) {
                        if let p = selectedProduct {
                            Text("开通 \(p.label.isEmpty ? "套餐" : p.label) 用量 · \(p.days) 天 ¥")
                            AnimatedNumber(
                                value: Double(p.priceCents) / 100, specifier: "%.1f",
                                font: .system(size: 15, weight: .semibold), color: .white
                            )
                        } else {
                            Text("开通套餐")
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.top, 2)
            .padding(.bottom, 20)
        }
    }

    /// 划线原价：现价 ÷ 0.9 向上取整再减 0.1，得到 16.9 / 24.9 / 49.9 / 97.9。
    private func origPriceValue(_ cents: Int) -> Double {
        let y = Double(cents) / 100.0
        return (y / 0.9).rounded(.up) - 0.1
    }

    private func usageLine(_ prod: APIClient.ShopProduct, ratio: Double) -> some View {
        let f = Font.system(size: 12.5)
        let c = AE.textSecondary
        return HStack(spacing: 0) {
            if prod.percent > 100 {
                Text("是基础用量的 ")
                AnimatedNumber(value: ratio, specifier: "%.1f", font: f, color: c)
                Text(" 倍 · ")
            } else {
                Text("基础用量")
                if prod.percent > 0 { Text(" · ") }
            }
            if prod.percent > 0 {
                AnimatedNumber(value: prod.percent, font: f, color: c, suffix: "%")
            }
        }
        .font(f)
        .foregroundStyle(c)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private var strikeLine: some View {
        Rectangle()
            .fill(AE.textSecondary.opacity(0.7))
            .frame(height: 0.8)
            .offset(y: -0.7)
    }

    /// 档位卡：大字档位名（字母数变化 spring 过渡）+ 推荐徽章 + 倍数说明
    /// + 右侧划线原价 / 大号现价（%.1f）/ 月；选中态用 AE 会员语义色深色适配。
    private func memberCell(_ prod: APIClient.ShopProduct) -> some View {
        let on = selectedProduct?.id == prod.id
        let label = prod.label.isEmpty ? (prod.title.isEmpty ? "\(prod.days) 天" : prod.title) : prod.label
        let name = "\(label) 用量"
        let ratio = Double(prod.percent) / 100.0
        let recommended = prod.id == "p_xl"
        let orig = origPriceValue(prod.priceCents)

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedProduct = prod }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                            .foregroundStyle(AE.memberAccent)
                            .scaleEffect(on ? 1.0 : 0.98)
                            // X → XL → XXL 字母增减：按选中档位 id 变化触发 spring
                            .animation(.spring(response: 0.32, dampingFraction: 0.82),
                                       value: selectedProduct?.id)
                        if recommended {
                            Text("推荐")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2.5)
                                .background(AE.memberBadge, in: Capsule())
                        }
                    }
                    usageLine(prod, ratio: ratio)
                    // 服务端明面价：list_price_cents / discount_percent（未虚标则与现价一致）
                    Text("面价 ¥\(String(format: "%.2f", Double(prod.listPriceCents > 0 ? prod.listPriceCents : prod.priceCents) / 100)) · \(prod.discountPercent)%")
                        .font(.system(size: 10))
                        .foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    AnimatedNumber(
                        value: orig, specifier: "¥%.1f",
                        font: .system(size: 11.5), color: AE.textSecondary
                    )
                    .overlay(alignment: .center) { strikeLine }
                    AnimatedNumber(
                        value: Double(prod.priceCents) / 100, specifier: "¥%.1f",
                        font: .system(size: 25, weight: .heavy, design: .rounded), color: AE.memberAccent
                    )
                    Text("/月").font(.system(size: 10.5)).foregroundStyle(AE.textSecondary)
                }
            }
            .padding(.horizontal, 17).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22, material: .regular,
                       tint: on ? AE.memberCardTint : AE.card,
                       tintOpacity: on ? 0.72 : 0.10,
                       strokeColor: on ? AE.memberCardStroke : AE.cardStroke,
                       strokeOpacity: on ? 0.45 : 0.16)
            .shadow(color: AE.shadowColor, radius: 9, y: 3)
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: on)
    }

    // MARK: - 通用按钮

    private func payButton<L: View>(
        enabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> L
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(enabled ? AE.accentDeep : AE.accentDeep.opacity(0.4), in: Capsule())
                .shadow(color: enabled ? AE.accentDeep.opacity(0.24) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }

    // MARK: - 支付（会员套餐）

    @MainActor
    private func startPay(_ channel: PayChannel) async {
        showChannelPicker = false
        guard let token = session.token, !token.isEmpty else { showTip("请先登录"); return }
        do {
            guard let prod = selectedProduct else { return }
            let order = try await APIClient.memberOrder(
                productID: prod.id, payType: channel.rawValue, token: token)
            guard !order.payURL.isEmpty else { showTip("支付链接为空，请稍后重试"); return }
            activePay = ActivePay(order: order, title: "开通 \(prod.label.isEmpty ? "套餐" : prod.label) 用量 · \(prod.days) 天")
            if channel == .alipay {
                showAlipayConfirm = true
                if let url = URL(string: order.payURL) {
                    await UIApplication.shared.open(url)
                }
            } else {
                showWeChatQR = true
            }
        } catch {
            showTip("下单失败：\(error.localizedDescription)")
        }
    }

    private func verifyActivePay() async throws -> APIClient.PayVerifyResult {
        guard let active = activePay, let token = session.token else {
            throw APIError.decode("订单信息丢失，请重新下单")
        }
        switch active.order.kind {
        case .points:
            let r = try await APIClient.pointsOrderStatus(orderNo: active.order.orderID, token: token)
            return APIClient.PayVerifyResult(paid: r.paid, amount: r.points, unit: "墨点")
        case .member:
            let r = try await APIClient.memberOrderStatus(orderID: active.order.orderID, token: token)
            return APIClient.PayVerifyResult(paid: r.paid, amount: r.days, unit: "天会员")
        }
    }

    @MainActor
    private func onPaid(_ result: APIClient.PayVerifyResult) {
        showWeChatQR = false
        showAlipayConfirm = false
        successResult = result
        showSuccess = true
    }

    // MARK: - 支付弹层

    private var channelPicker: some View {
        ZStack {
            GlassBackdrop()
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("选择支付方式")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(AE.accent)
                        Text(activePay?.title ?? "到账后立即生效")
                            .font(.system(size: 12))
                            .foregroundStyle(AE.textSecondary)
                    }
                    Spacer(minLength: 8)
                    Button { showChannelPicker = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AE.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AE.accentSoft, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 2)

                channelRow(title: "支付宝", note: "跳转支付宝收银台完成付款",
                           glyph: "A", tint: AE.payAlipay) { Task { await startPay(.alipay) } }
                channelRow(title: "微信支付", note: "玻璃二维码，扫码付款",
                           glyph: "微", tint: AE.payWechat) { Task { await startPay(.wxpay) } }

                Text("付款完成后回到本页确认到账")
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 12)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .glassSheetBackground()
        .onAppear { activePay = nil }
    }

    private func channelRow(
        title: String, note: String, glyph: String, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint).frame(width: 40, height: 40)
                    Text(glyph)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(AE.textPrimary)
                    Text(note).font(.system(size: 11.5)).foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.textSecondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16, material: .thin, tintOpacity: 0.16)
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
    }

    private var weChatQRSheet: some View {
        PayQRView(
            payment: activePay?.order.payURL ?? "",
            title: "扫码支付 · " + (activePay?.title ?? "")
        ) {
            try await verifyActivePay()
        } onPaid: { result in
            onPaid(result)
        }
        .environmentObject(session)
        .presentationDetents([.fraction(0.78)])
        .glassSheetBackground()
    }

    private var alipayConfirmSheet: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(AE.payAlipay.opacity(0.16)).frame(width: 62, height: 62)
                Image(systemName: "hand.raised.fill").font(.system(size: 26)).foregroundStyle(AE.payAlipay)
            }
            Text("已跳转支付宝")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(AE.accent)
            Text("在支付宝完成付款后，回到这里点「我已支付」确认到账")
                .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)
            if let a = activePay {
                Text(a.title).font(.system(size: 13, weight: .medium)).foregroundStyle(AE.textPrimary)
            }
            HStack(spacing: 10) {
                Button { showAlipayConfirm = false } label: {
                    Text("取消").font(.system(size: 15, weight: .medium)).foregroundStyle(AE.accent)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .glassCard(cornerRadius: 23, material: .thin, tintOpacity: 0.08, strokeOpacity: 0.18)
                }
                .buttonStyle(.plain)
                Button { Task { await confirmAlipay() } } label: {
                    Text(alipayConfirming ? "正在确认支付…" : "我已支付")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(alipayConfirming ? AE.accentDeep.opacity(0.45) : AE.accentDeep, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(alipayConfirming)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
        .glassSheetBackground()
    }

    @MainActor
    private func confirmAlipay() async {
        guard !alipayConfirming else { return }
        alipayConfirming = true
        var result: APIClient.PayVerifyResult? = nil
        for _ in 0..<12 {
            if Task.isCancelled { break }
            do {
                let r = try await verifyActivePay()
                if r.paid { result = r; break }
            } catch { /* 网络抖动，下一轮重试 */ }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        alipayConfirming = false
        if let r = result {
            onPaid(r)
        } else {
            showTip("支付失败，请确认已付款后重试")
        }
    }

    private var successSheet: some View {
        Group {
            if let r = successResult {
                PaySuccessView(
                    amount: r.amount,
                    unit: r.unit,
                    subtitle: "会员有效期已续期",
                    onDone: { Task { await load() } }
                )
            }
        }
        .presentationDetents([.medium])
        .glassSheetBackground()
    }
}
