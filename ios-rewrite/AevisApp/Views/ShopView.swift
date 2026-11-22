import SwiftUI
import UIKit

/// 商城页（第 3 轮，全屏）：4 tab —— 墨点 / 会员套餐 / 重置卡 / 按次。
///
/// 布局要点：**全屏**，标题 + 余额 + SegmentedTabs 固定，内容区吃满剩余高度；
/// 滚动放在每个 tab 分支内部（安卓踩过「外层滚动 + 内容动画被撑出屏幕」的坑，
/// 这里绝不外层套 ScrollView）。内容切 tab 时按方向淡入横移（forward = target > prev）。
///
/// 支付流程（第 3 轮接通）：
///   选支付方式（支付宝 / 微信）→ 下单拿 pay_url：
///     - 支付宝：`UIApplication.open(pay_url)` 跳收银台，回来点「我已支付」查单；
///     - 微信：复用 `PayQRView(payment:)` 玻璃二维码弹窗，扫码付款后点「我已支付」查单。
///   查单确认 state==paid → `PaySuccessView` 一笔画勾动效 →「我已完成」刷新余额 / 会员。
///   tab 状态：墨点充值 / 会员套餐走真接口；重置卡无商品接口禁用；按次开关可热更新。
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    @State private var tab = 0
    @State private var prevTab = 0
    @State private var balance: Int? = nil          // nil = 取不到，显示「—」不显示 0
    @State private var memberDays: Int? = nil       // 会员剩余天数（刷新后更新）
    @State private var packages: [APIClient.PointPackage] = []
    @State private var products: [APIClient.ShopProduct] = []
    @State private var selectedPackage: APIClient.PointPackage? = nil
    @State private var selectedProduct: APIClient.ShopProduct? = nil
    @State private var tip = ""

    // 支付流程状态
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

    /// 按次 tab 热更新开关：以后上线只改这个开关即可显示真内容，无需更新 App。
    @AppStorage("aevisPayPerUseEnabled") private var perUseEnabled = false

    private var forward: Bool { tab >= prevTab }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题 + 返回
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("商城").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            // 墨点余额（数字滚动）
            HStack(spacing: 6) {
                Text("墨点余额")
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                if let b = balance {
                    AnimatedNumber(value: b, font: .system(size: 16, weight: .bold, design: .rounded), color: AE.accent)
                } else {
                    Text("—").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(AE.accent)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            SegmentedTabs(tabs: ["墨点", "会员套餐", "重置卡", "按次"], selected: Binding(
                get: { tab },
                set: { new in if new != tab { prevTab = tab; tab = new } }
            ))
                .frame(height: 38)
                .padding(.horizontal, 18)
                .padding(.top, 12)

            ZStack {
                contentForTab(tab)
                    .id(tab)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.18), value: tab)

            if !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .background(AppBackground())
        .task { await load() }
        // 支付方式选择
        .sheet(isPresented: $showChannelPicker) { channelPicker }
        // 微信：玻璃二维码 + 我已支付查单
        .sheet(isPresented: $showWeChatQR) { weChatQRSheet }
        // 支付宝：跳转收银台后的到账确认
        .sheet(isPresented: $showAlipayConfirm) { alipayConfirmSheet }
        // 支付成功动效
        .sheet(isPresented: $showSuccess) { successSheet }
    }

    @ViewBuilder
    private func contentForTab(_ index: Int) -> some View {
        switch index {
        case 0: pointsTab
        case 1: memberTab
        case 2: resetCardTab
        default: perUseTab
        }
    }

    // MARK: - 加载 / 刷新

    private func load() async {
        async let p = APIClient.pointPackages()
        async let s = APIClient.shopProducts()
        async let b = APIClient.pointsBalance(token: session.token)
        async let days = APIClient.membershipDays(token: session.token ?? "")
        let pkgs = (try? await p) ?? []
        let prods = (try? await s) ?? []
        let bal = (try? await b)         // 失败保持 nil → 显示「—」
        let mDays = (try? await days)    // 失败保持 nil → 显示「未开通」
        await MainActor.run {
            packages = pkgs
            products = prods
            balance = bal
            memberDays = mDays
            if selectedPackage == nil { selectedPackage = pkgs.first }
            if selectedProduct == nil { selectedProduct = prods.first }
        }
    }

    // MARK: - tab 0 墨点充值

    private var pointsTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前墨点")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                    if let b = balance {
                        AnimatedNumber(value: b, font: .system(size: 26, weight: .bold, design: .rounded))
                    } else {
                        Text("—").font(.system(size: 26, weight: .bold, design: .rounded))
                    }
                    if let sel = selectedPackage {
                        Text("充值后到账 \(sel.points) 墨点")
                            .font(.system(size: 12))
                            .foregroundStyle(AE.brandPurple)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular)

                Text("选择档位").font(.system(size: 13, weight: .medium)).foregroundStyle(AE.textSecondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(packages) { pkg in packageCell(pkg) }
                }

                if packages.isEmpty {
                    Text("档位加载中或暂不可用")
                        .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }

                payButton(
                    title: "立即充值" + (selectedPackage.map { " ¥\($0.amountYuan)" } ?? ""),
                    enabled: selectedPackage != nil
                ) { showChannelPicker = true }
            }
            .padding(18)
        }
    }

    private func packageCell(_ pkg: APIClient.PointPackage) -> some View {
        let on = selectedPackage?.code == pkg.code
        return Button { selectedPackage = pkg } label: {
            VStack(spacing: 5) {
                if !pkg.pointsText.isEmpty {
                    Text(pkg.pointsText)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                }
                Text(pkg.name)
                    .font(.system(size: 12)).foregroundStyle(AE.textSecondary).lineLimit(1)
                AnimatedNumber(
                    value: Double(pkg.amountCents) / 100, specifier: "¥%.2f",
                    font: .system(size: 14, weight: .semibold), color: AE.accent
                )
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .glassCard(cornerRadius: 14, material: .thin,
                       tintOpacity: on ? 0.22 : 0.08,
                       strokeColor: on ? AE.brandPurple : .white,
                       strokeOpacity: on ? 0.9 : 0.18)
        }
        .buttonStyle(AevisPressStyle(scale: 0.96))
    }

    // MARK: - tab 1 会员套餐

    private var memberTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AevisMascot(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前方案").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        if let d = memberDays, d > 0 {
                            AnimatedNumber(value: d, font: .system(size: 18, weight: .bold, design: .rounded), suffix: " 天")
                                .foregroundStyle(AE.textPrimary)
                        } else {
                            Text("未开通")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                                .foregroundStyle(AE.textPrimary)
                        }
                        Text("固定 30 天 · 每周一刷新额度")
                            .font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular)

                Text("用量越多越划算 · 固定 30 天 · 每周一刷新额度")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AE.brandPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(products) { prod in memberCell(prod) }
                if products.isEmpty {
                    Text("套餐加载中或暂不可用")
                        .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }

                payButton(
                    title: selectedProduct.map { p in
                        "开通 \(p.label.isEmpty ? "会员" : p.label) · \(p.days) 天 ¥\(String(format: "%.0f", Double(p.priceCents)/100))"
                    } ?? "开通会员",
                    enabled: selectedProduct != nil
                ) { showChannelPicker = true }
            }
            .padding(18)
        }
    }

    /// 划线原价：现价 ÷ 0.9 向上取整再减 0.1，得到 16.9 / 24.9 / 49.9 / 97.9
    /// —— 对齐参考图「¥12.9 ¥11.61/月」那种「原价划线 + 现价」的写法。
    private func origPrice(_ cents: Int) -> String {
        let y = Double(cents) / 100.0
        let o = (y / 0.9).rounded(.up) - 0.1
        return String(format: "%.1f", o)
    }

    private func ratioText(_ r: Double) -> String {
        r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
    }

    /// 会员档位卡：照参考图版式 —— 大字档位名 + 推荐徽章 + 「是基础用量的 X 倍」
    /// + 右侧「划线原价 / 大号现价 / 月」；选中态是淡黄磨砂玻璃 + 描边。
    private func memberCell(_ prod: APIClient.ShopProduct) -> some View {
        let on = selectedProduct?.id == prod.id
        let name = prod.label.isEmpty ? (prod.title.isEmpty ? "\(prod.days) 天会员" : prod.title) : prod.label
        let ratio = Double(prod.percent) / 100.0
        // 2026-11-22 用户要求：不写具体墨点数，只讲相对倍数 + 百分比
        let baseText = prod.percent <= 100 ? "基础用量" : "是基础用量的 \(ratioText(ratio)) 倍"
        let scaleText = prod.percent > 0 ? "\(baseText) · \(prod.percent)%" : baseText
        // 推荐位：第二档（XL）对齐参考图 Plus 的「推荐」徽章
        let recommended = prod.id == "p_xl"
        let orig = origPrice(prod.priceCents)

        return Button { selectedProduct = prod } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                            .foregroundStyle(AE.accentDeep)
                        if recommended {
                            Text("推荐")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2.5)
                                .background(Color.hex(0xE08A2E), in: Capsule())
                        }
                    }
                    Text(scaleText)
                        .font(.system(size: 12.5)).foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("¥\(orig)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                        .strikethrough(true, color: AE.textSecondary.opacity(0.7))
                    AnimatedNumber(
                        value: Double(prod.priceCents) / 100, specifier: "¥%.0f",
                        font: .system(size: 25, weight: .heavy, design: .rounded), color: AE.accentDeep
                    )
                    Text("/月").font(.system(size: 10.5)).foregroundStyle(AE.textSecondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 22, material: .regular,
                       tint: on ? Color.hex(0xF2E2A8) : .white,
                       tintOpacity: on ? 0.72 : 0.10,
                       strokeColor: on ? Color.hex(0x8C8A80) : .white,
                       strokeOpacity: on ? 0.45 : 0.16)
        }
        .buttonStyle(AevisPressStyle(scale: 0.98))
    }

    // MARK: - tab 2 重置卡

    private var resetCardTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AE.brandPurple.opacity(0.16)).frame(width: 44, height: 44)
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 22)).foregroundStyle(AE.brandPurple)
                    }
                    Text("重置卡 · 单次重置")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(AE.textPrimary)
                    Text("立即恢复本周全部用量。免费版每张限用一次。")
                        .font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                    Divider().opacity(0.4)
                    HStack {
                        Text("本周剩余").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        Spacer()
                        Text(balance.map { "\($0) 墨点" } ?? "—")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(AE.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular)

                Button { } label: {
                    Text("暂未开放购买")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .background(AE.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
            .padding(18)
        }
    }

    // MARK: - tab 3 按次（热更新开关）

    private var perUseTab: some View {
        Group {
            if perUseEnabled {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("按次包").font(.system(size: 16, weight: .semibold)).foregroundStyle(AE.textPrimary)
                        Text("选择次数包，即用即扣。").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                            ForEach([100, 500, 1000, 3000], id: \.self) { n in
                                VStack(spacing: 4) {
                                    Text("\(n) 次").font(.system(size: 16, weight: .bold)).foregroundStyle(AE.textPrimary)
                                    Text("按次包").font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .glassCard(cornerRadius: 14, material: .thin)
                            }
                        }
                    }.padding(18)
                }
            } else {
                VStack(spacing: 14) {
                    Spacer(minLength: 60)
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AE.accentSoft.opacity(0.5)).frame(width: 60, height: 60)
                        Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(AE.accent)
                    }
                    Text("按次包 · 暂未上线")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(AE.textPrimary)
                    Text("上线后自动开放，无需更新 App")
                        .font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                    Spacer(minLength: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - 通用按钮

    private func payButton(title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(enabled ? AE.accentDeep : AE.accentDeep.opacity(0.4), in: Capsule())
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

    // MARK: - 支付：下单

    /// 支付方式确定后下单：支付宝拿 pay_url 跳收银台；微信拿 pay_url 显示二维码弹窗。
    @MainActor
    private func startPay(_ channel: PayChannel) async {
        showChannelPicker = false
        guard let token = session.token, !token.isEmpty else { showTip("请先登录"); return }
        do {
            let order: APIClient.PayOrder
            let title: String
            if tab == 0 {
                guard let pkg = selectedPackage else { return }
                order = try await APIClient.pointsRecharge(package: pkg.code, payType: channel.rawValue, token: token)
                title = "充值 \(pkg.points) 墨点"
            } else {
                guard let prod = selectedProduct else { return }
                order = try await APIClient.memberOrder(productID: prod.id, payType: channel.rawValue, token: token)
                title = "开通 \(prod.label.isEmpty ? "会员" : prod.label) · \(prod.days) 天"
            }
            guard !order.payURL.isEmpty else { showTip("支付链接为空，请稍后重试"); return }
            activePay = ActivePay(order: order, title: title)
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

    /// 按当前订单类型查单（供 PayQRView / 支付宝确认复用）。
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

    /// 到账回调：关闭支付弹层，弹成功动效。
    @MainActor
    private func onPaid(_ result: APIClient.PayVerifyResult) {
        showWeChatQR = false
        showAlipayConfirm = false
        successResult = result
        showSuccess = true
    }

    // MARK: - 支付：弹层

    private var channelPicker: some View {
        VStack(spacing: 14) {
            Text("选择支付方式")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(AE.accent)
            if let a = activePay { Text(a.title).font(.system(size: 12)).foregroundStyle(AE.textSecondary) }

            Button { Task { await startPay(.alipay) } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.hex(0x1677FF).opacity(0.16)).frame(width: 40, height: 40)
                        Image(systemName: "a.circle.fill").font(.system(size: 20)).foregroundStyle(Color.hex(0x1677FF))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("支付宝").font(.system(size: 15, weight: .semibold)).foregroundStyle(AE.textPrimary)
                        Text("跳转支付宝收银台完成付款").font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                }
                .padding(12)
                .glassCard(cornerRadius: 14, material: .thin, tintOpacity: 0.12)
            }
            .buttonStyle(.plain)

            Button { Task { await startPay(.wxpay) } } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.hex(0x1AAD19).opacity(0.16)).frame(width: 40, height: 40)
                        Image(systemName: "message.circle.fill").font(.system(size: 20)).foregroundStyle(Color.hex(0x1AAD19))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("微信支付").font(.system(size: 15, weight: .semibold)).foregroundStyle(AE.textPrimary)
                        Text("玻璃二维码，扫码付款").font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                }
                .padding(12)
                .glassCard(cornerRadius: 14, material: .thin, tintOpacity: 0.12)
            }
            .buttonStyle(.plain)

            Button("取消") { showChannelPicker = false }
                .font(.system(size: 14)).foregroundStyle(AE.textSecondary)
                .padding(.top, 2)
        }
        .padding(24)
        .presentationDetents([.medium])
        .glassSheetBackground()
        .onAppear { activePay = nil }
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
        .presentationDetents([.large])
        .glassSheetBackground()
    }

    private var alipayConfirmSheet: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.hex(0x1677FF).opacity(0.16)).frame(width: 62, height: 62)
                Image(systemName: "hand.raised.fill").font(.system(size: 26)).foregroundStyle(Color.hex(0x1677FF))
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

    /// 支付宝到账确认：每 2 秒查单，最多 12 次；到账 → 成功动效；超时 → 提示重试。
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
                    subtitle: r.unit == "墨点" ? "墨点余额已更新" : "会员有效期已续期",
                    onDone: {
                        Task { await load() }   // 刷新余额 / 会员
                    }
                )
            }
        }
        .presentationDetents([.medium])
        .glassSheetBackground()
    }
}
