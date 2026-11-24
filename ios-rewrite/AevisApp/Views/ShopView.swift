import SwiftUI
import UIKit

/// 商城页（2026-11-23 拆分后）：3 tab —— 墨点 / 重置卡 / 按次。
///
/// 会员套餐已整体迁到独立 `MemberView.swift`，由主页「会员」入口全屏拉起；
/// 本页只讲墨点（及重置卡/按次占位）。两页各自持有一套支付状态，复用 `PayQRView`/`PaySuccessView`，
/// 返回层级不串。用户可见文案统一用「套餐」（本页已无会员 tab）。
///
/// 布局要点：**全屏**，标题 + 余额 + SegmentedTabs 固定，内容区吃满剩余高度；
/// 滚动放在每个 tab 分支内部（安卓踩过「外层滚动 + 内容动画被撑出屏幕」的坑，
/// 这里绝不外层套 ScrollView）。内容切 tab 时按方向淡入横移（forward = target > prev）。
///
/// ⚠️ R2.9：墨点（points）与额度（quota）彻底分离 ——
/// 顶部「墨点余额」来自 `/v1/points`，重置卡 tab 的「本周剩余」来自 `/v1/quota/state`
/// 的 `leftPct`（只显示百分比）。两者互不顶替，取数失败都显示「—」，不回落写死数字。
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    /// 入口可指定初始 tab：主页「按次计费」直接落到第 3 个 tab（index 2）。
    private let initialTab: Int
    @State private var tab
    @State private var prevTab

    init(initialTab: Int = 0) {
        self.initialTab = min(max(initialTab, 0), 2)
        _tab = State(initialValue: self.initialTab)
        _prevTab = State(initialValue: self.initialTab)
    }
    @State private var balance: Int? = nil          // nil = 取不到，显示「—」不显示 0
    @State private var quota: APIClient.QuotaState? = nil // 本周剩余额度%，与墨点余额分开
    @State private var packages: [APIClient.PointPackage] = []
    @State private var selectedPackage: APIClient.PointPackage? = nil
    @State private var tip = ""

    // 支付流程状态（本页只处理墨点充值；会员支付在 MemberView 内自成一套）
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

            // 墨点余额（数字滚动）—— 只出现在墨点相关处，不冒充额度
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

            SegmentedTabs(tabs: ["墨点", "重置卡", "按次"], selected: Binding(
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
            .clipped()   // 防档位卡 spring 越界留残影
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
        .sheet(isPresented: $showChannelPicker) { channelPicker }
        .sheet(isPresented: $showWeChatQR) { weChatQRSheet }
        .sheet(isPresented: $showAlipayConfirm) { alipayConfirmSheet }
        .sheet(isPresented: $showSuccess) { successSheet }
    }

    @ViewBuilder
    private func contentForTab(_ index: Int) -> some View {
        switch index {
        case 0: pointsTab
        case 1: resetCardTab
        default: perUseTab
        }
    }

    // MARK: - 加载 / 刷新

    private func load() async {
        async let p = APIClient.pointPackages()
        async let b = APIClient.pointsBalance(token: session.token)
        async let q = APIClient.quotaState(token: session.token)
        let pkgs = (try? await p) ?? []
        let bal = (try? await b)         // 失败保持 nil → 显示「—」
        let qt = (try? await q)          // 失败保持 nil → 显示「—」
        await MainActor.run {
            packages = pkgs
            balance = bal
            quota = qt
            if selectedPackage == nil { selectedPackage = pkgs.first }
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
                    // R2.5：到账数字随档位切换滚动（不是硬切 Text）
                    if let sel = selectedPackage {
                        HStack(spacing: 0) {
                            Text("充值后到账 ")
                            AnimatedNumber(
                                value: sel.points,
                                font: .system(size: 12, weight: .medium),
                                color: AE.brandPurple
                            )
                            Text(" 墨点")
                        }
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

                payButton(enabled: selectedPackage != nil, action: { showChannelPicker = true }) {
                    HStack(spacing: 0) {
                        Text("立即充值")
                        if let sel = selectedPackage {
                            Text(" ")
                            AnimatedNumber(
                                value: Double(sel.amountCents) / 100,
                                specifier: sel.amountCents % 100 == 0 ? "¥%.0f" : "¥%.2f",
                                font: .system(size: 15, weight: .semibold), color: .white
                            )
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func packageCell(_ pkg: APIClient.PointPackage) -> some View {
        let on = selectedPackage?.code == pkg.code
        return Button { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selectedPackage = pkg } } label: {
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
                       strokeColor: on ? AE.brandPurple : AE.cardStroke,
                       strokeOpacity: on ? 0.9 : 0.18)
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: on)
    }

    // MARK: - tab 1 重置卡

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
                        // R2.9：这里是额度百分比，来自 /v1/quota/state.leftPct；
                        // 绝不是墨点余额 balance。取不到显示「—」，不回落写死数字。
                        Text(quota.map { "\($0.leftPct)%" } ?? "—")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(AE.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular)

                // 暂未开放：纯文字说明，不做成按钮（用户要求：没实现的不要能点的样子）
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .padding(.top, 1)
                    Text("重置卡暂未开放购买，开放后会直接出现在这里。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .padding(18)
        }
    }

    // MARK: - tab 2 按次（DeepSeek 按次，价格全部明面）

    /// 按次套餐（2026-11-24 用户口径：DeepSeek 按次，1 元 = 50 次、2 元 = 100 次，
    /// 默认 100 次起卖）。后端目前没有按次下单接口，本 tab 先做**明示价格 UI**，
    /// 不做假的「立即购买」按钮；需后端补 product/order 接口后才能真正下单。
    private struct PerUsePackage: Identifiable {
        let id = UUID()
        let yuan: String
        let times: Int
        let isDefault: Bool
    }

    private let perUsePackages: [PerUsePackage] = [
        PerUsePackage(yuan: "1.00", times: 50, isDefault: false),
        PerUsePackage(yuan: "2.00", times: 100, isDefault: true),
    ]

    private var perUseTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("DeepSeek 按次").font(.system(size: 16, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Text("默认 100 次起卖 · 即用即扣，所有价格明面展示")
                    .font(.system(size: 12)).foregroundStyle(AE.textSecondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    ForEach(perUsePackages) { pack in
                        VStack(spacing: 5) {
                            HStack(spacing: 4) {
                                Text("¥\(pack.yuan)")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(AE.accent)
                                if pack.isDefault {
                                    Text("默认")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                        .background(AE.brandPurple, in: Capsule())
                                }
                            }
                            Text("\(pack.times) 次")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(AE.textPrimary)
                            Text(String(format: "内部价 ¥%.2f / 次", Double(pack.yuan) ?? 0 / Double(pack.times)))
                                .font(.system(size: 10.5))
                                .foregroundStyle(AE.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .glassCard(cornerRadius: 14, material: .thin,
                                   tintOpacity: pack.isDefault ? 0.20 : 0.08,
                                   strokeColor: pack.isDefault ? AE.brandPurple : AE.cardStroke,
                                   strokeOpacity: pack.isDefault ? 0.8 : 0.18)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("token 限量说明").font(.system(size: 12.5, weight: .medium)).foregroundStyle(AE.textPrimary)
                    Text("每一轮对话最多计入 2000 token，超出部分按服务端实际口径另计；设置上限是为了防止次数包被少量高消耗对话吃穿。具体上限以服务端配置为准。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.12)

                Text("下单入口待后端补齐按次商品与订单接口后开放。")
                    .font(.system(size: 11)).foregroundStyle(AE.textSecondary)
            }
            .padding(18)
        }
    }

    // MARK: - 通用按钮

    /// 主操作按钮：内容由调用方给，数字可塞 `AnimatedNumber`。
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

    // MARK: - 支付：下单（仅墨点充值）

    @MainActor
    private func startPay(_ channel: PayChannel) async {
        showChannelPicker = false
        guard let token = session.token, !token.isEmpty else { showTip("请先登录"); return }
        do {
            guard let pkg = selectedPackage else { return }
            let order = try await APIClient.pointsRecharge(
                package: pkg.code, payType: channel.rawValue, token: token)
            guard !order.payURL.isEmpty else { showTip("支付链接为空，请稍后重试"); return }
            activePay = ActivePay(order: order, title: "充值 \(pkg.points) 墨点")
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

    /// 查单：本页只有墨点订单。member 分支仅为 `PayOrder.Kind` 枚举穷尽保留，正常不可达。
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

    // MARK: - 支付：弹层

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

                channelRow(
                    title: "支付宝",
                    note: "跳转支付宝收银台完成付款",
                    glyph: "A",
                    tint: AE.payAlipay
                ) { Task { await startPay(.alipay) } }

                channelRow(
                    title: "微信支付",
                    note: "玻璃二维码，扫码付款",
                    glyph: "微",
                    tint: AE.payWechat
                ) { Task { await startPay(.wxpay) } }

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
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
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
                    subtitle: "墨点余额已更新",
                    onDone: { Task { await load() } }
                )
            }
        }
        .presentationDetents([.medium])
        .glassSheetBackground()
    }
}
