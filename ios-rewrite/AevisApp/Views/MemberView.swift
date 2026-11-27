import SwiftUI
import UIKit

/// 会员独立页（2026-11-23 从 `ShopView` 迁出）：只承载「套餐」。
///
/// - 现价来自 `ShopProduct.priceCents`，一律 `specifier:"%.1f"`，
///   否则 14.9 会被 `%.0f` 吞成 "¥15"；划线原价 `origPriceValue` 用 `¥%.1f`。
/// - **档位数量由服务端决定，不写死**。2026-11-25 起线上只保留一档（`p_x` ¥14.9 / 30 天），
///   `p_xl` / `p_xxl` / `p_xllll` 已 `active=0` 下架（行还在，随时可恢复）。所以：
///   列表是**纵向 `ForEach`**，不是横向分页 —— 一档时就是一张卡，不会留空位、也没有「1/4」这类位置指示；
///   所有用到 `products.first` 的地方（`discountProduct`、`displayedBenefits`）都走可选绑定，
///   空数组和单元素数组都不会越界。
/// - 九折弹窗：**每天第一次进会员页弹一次**（`aevisMemberDiscountLastShownDate` 存本地 yyyy-MM-dd，
///   跨天自动重置、同日不重复、可关闭）；页面常驻「限时九折」入口可再次手动查看。
///   强制更新逻辑（AppUpdate/UpdateSheet）完全不碰。
/// - `memberDays <= 0` 时顶部「当前方案」整块不渲染（不是显示「未开通」）。
/// - 支付流程自成一套（复用 `PayQRView` / `PaySuccessView`），与商城墨点支付互不干扰。
/// - 夜间配色收敛到 `AE` 会员语义色（`Color.adaptive`），浅色保持原值。
/// - **本页只收 `kind == "member"` 的商品**：`/v1/shop/products` 把会员档与按次包混在一个
///   数组里下发，不过滤会把「DeepSeek 按次 100/200 次」当成会员档摆出来（线上 bug）。
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
    /// 会员权益二级页（2026-11-25）
    @State private var showBenefits = false

    // 支付流程状态（与商城页各自持有一套）
    private enum PayChannel: String { case alipay, wxpay }
    private struct ActivePay {
        let order: APIClient.PayOrder
        let title: String
        /// 用户下单时选的渠道；聚合码下两边二维码一样，仅用于回落文案。
        let channel: String
    }
    @State private var showChannelPicker = false
    @State private var activePay: ActivePay? = nil
    @State private var showWeChatQR = false
    @State private var showSuccess = false
    @State private var successResult: APIClient.PayVerifyResult? = nil

    /// 会员权益（本地兜底文案）。后端 `/v1/shop/products` 已下发 `benefits[]`（4 条），
    /// 只有老服务端缺字段时才用这里，保证权益区不空白。
    ///
    /// 2026-11-25：**删掉「免费时长」**。后端 `benefits[]` 现在不含语音分钟这一项，
    /// 本地兜底若还留着，服务端字段缺失时会把已下线的权益又摆出来。
    /// 2026-11-27 会员权益口径（用户原话）：「会员是签到加每日赠送，每日签到加充值卡」
    /// → 权益只讲签到 / 每日赠送 / 充值卡 / 有效期，**不把聊天额度包塞进会员页**。
    private let benefitItems = [
        "每日签到，会员双倍奖励",
        "每日赠送墨点，每周一到账",
        "充值卡 · 墨点充值会员专享",
        "开通立得 300 墨点",
        "固定 30 天，到期不自动续费",
    ]

    /// 后端 `/v1/shop/products` 已下发 `benefits[]`（字符串数组），优先用服务端文案；
    /// 老服务端缺字段时回落本地占位，不让权益区空白。
    /// 注意 `products` 只含会员档（`load()` 里已按 kind 过滤），这里的 `products.first`
    /// 兜底不会拿到按次商品。
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
                Text("AEVIS 会员").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
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
        // 贴底支付栏（2026-11-25）：开通按钮不跟着滚。
        .safeAreaInset(edge: .bottom, spacing: 0) { stickyPayBar }
        .navigationTitle("AEVIS 会员")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showDiscount) { discountSheet }
        .sheet(isPresented: $showBenefits) { benefitsSheet }
        .sheet(isPresented: $showChannelPicker) { channelPicker }
        .sheet(isPresented: $showWeChatQR) { weChatQRSheet }
        .sheet(isPresented: $showSuccess) { successSheet }
    }

    /// 底部固定「立即开通」栏。现价用 `%.1f` 保住 .9 尾数，切档位时数字联动滚动。
    private var stickyPayBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.18)
            // 2026-11-27 用户：聚合支付，不再让用户选微信/支付宝，点了直接出二维码。
            payButton(enabled: selectedProduct != nil, action: { Task { await startPay(.wxpay) } }) {
                HStack(spacing: 0) {
                    if let p = selectedProduct {
                        Text("开通 AEVIS 会员 · \(p.days) 天 ¥")
                        AnimatedNumber(
                            value: Double(p.priceCents) / 100, specifier: "%.1f",
                            font: .system(size: 15, weight: .semibold), color: .white
                        )
                    } else {
                        Text("开通套餐")
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(
            LinearGradient(
                colors: [Color.clear, Color.paper.opacity(0.62)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - 会员权益二级页

    /// 权益列表（二级菜单）。文案来源：优先服务端 `benefits[]`，缺字段回落本地占位，
    /// 与 `displayedBenefits` 完全同一份数据 —— 入口上显示「N 项」也就不会和列表对不上。
    private var benefitsSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(displayedBenefits.enumerated()), id: \.offset) { idx, item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AE.brandPurple)
                                .padding(.top, 1)
                            Text(item)
                                .font(.system(size: 14))
                                .foregroundStyle(AE.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        if idx < displayedBenefits.count - 1 {
                            Divider()
                                .opacity(0.35)
                                .padding(.leading, 40)
                        }
                    }
                }
                .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.16)
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Text("权益随套餐档位变化，具体以服务端实际到账为准。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
            }
            .background(Color.clear)
            .navigationTitle("会员权益")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showBenefits = false }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .glassSheetBackground()
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

    /// 九折弹窗展示的档位：优先用户选中的，否则第一个会员档。
    /// `products` 已按 kind 过滤成纯会员档，`products.first` 可为 nil（加载中/失败）——
    /// 弹窗里对 `discountProduct` 全部做了可选绑定，空列表不会越界。
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
                Text("AEVIS 会员 · 固定 \(p.days) 天")
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
        // 2.8：首帧同步读硬缓存，价格和档位来自服务端下发，客户端不写死 14.9/19.9。
        if let raw = APIClient.cachedJSON(.shopProducts) {
            let cached = APIClient.parseShopProducts(raw).filter { $0.kind == "member" }
            if !cached.isEmpty {
                await MainActor.run {
                    products = cached
                    if selectedProduct == nil { selectedProduct = cached.first }
                }
            }
        }
        if let raw = APIClient.cachedJSON(.memberState, scope: APIClient.cacheScope) {
            let d = (raw["data"] as? [String: Any]) ?? raw
            if let m = d["membership"] as? [String: Any],
               let n = (m["days_left"] as? NSNumber)?.intValue {
                await MainActor.run { memberDays = n }
            }
        }
        async let s = APIClient.shopProducts()
        async let days = APIClient.membershipDays(token: session.token ?? "")
        let prods = (try? await s) ?? []
        // ⚠️ `/v1/shop/products` 是**混合数组**：会员四档（kind="member"）+ 按次两档
        // （kind="uses"，ds_use_100 / ds_use_200）共用同一个接口，靠 `kind` 区分。
        // 会员页只认 member，否则「DeepSeek 按次 100 次 / 200 次」会作为档位卡摆进套餐列表，
        // 用户点了「开通」以为在买会员（线上已踩过：「你的按次给我干会员了」）。
        // `ShopView` 那侧对称地只取 kind=="uses"，两边各拿各的，互不污染。
        // 容错：`kind` 解析时缺键默认 "member"（见 APIClient.shopProducts），所以老服务端不受影响。
        let memberProds = prods.filter { $0.kind == "member" }
        let mDays = (try? await days)
        await MainActor.run {
            products = memberProds
            memberDays = mDays
            // 选中项必须来自**过滤后**的数组。原来写的是 `prods.first`，
            // 一旦数组首元素是按次商品，就会选中一个根本不在列表里的档位，
            // 底部按钮会显示「开通 按次 用量 · 0 天 ¥2.0」并发出会员下单请求。
            // 这里同时覆盖两种情况：从未选过（nil）与选中的已不在列表里（脏值）。
            if !memberProds.contains(where: { $0.id == selectedProduct?.id }) {
                selectedProduct = memberProds.first
            }
            maybeShowDailyDiscount()
        }
    }

    // MARK: - 套餐列表

    private var memberTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // 会员定位说明。用量/额度详情在独立的「用量」页，这里不混着讲（2026-11-26 用户要求）
                Text("一个会员，解锁全部能力。30 天有效，到期不自动续费。")
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)

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

                // 会员权益（2026-11-25 改二级菜单）：不再把 5~6 条平铺在套餐页里
                // —— 平铺占掉半屏，把档位列表挤到折叠线以下。现在只留一行入口，
                // 点进去是独立列表，逐条列出。
                Button { showBenefits = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(AE.brandPurple)
                        Text("会员权益")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(AE.textPrimary)
                        Text("\(displayedBenefits.count) 项")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AE.textSecondary)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AE.textSecondary.opacity(0.45))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("固定 30 天 · 权益立即生效 · 每周一刷新")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AE.brandPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 1)

                ForEach(Array(products.enumerated()), id: \.element.id) { pair in
                    memberCell(pair.element).staggerIn(min(pair.offset, 3))
                }
                if products.isEmpty {
                    Text("套餐加载中或暂不可用")
                        .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                }

                // 选中项摘要：只说明「哪一档会员 / 多久 / 多少钱」，不展示用量倍数
                if let p = selectedProduct {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AE.memberAccent)
                        Text("AEVIS 会员 · \(p.days) 天")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                        Spacer(minLength: 6)
                        AnimatedNumber(
                            value: Double(p.priceCents) / 100, specifier: "¥%.1f",
                            font: .system(size: 13.5, weight: .bold, design: .rounded),
                            color: AE.memberAccent
                        )
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .glassCard(cornerRadius: 14, material: .thin, tintOpacity: 0.12)
                }
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
        // 会员卡只讲权益，不讲「基础用量倍数」—— 那是「用量」页的内容（2026-11-26 拆分）
        var parts: [String] = []
        if prod.grantPoints > 0 { parts.append("开通赠 \(prod.grantPoints) 墨点") }
        // 「每周 N 条」是额度口径，会员页不这么讲；这里只说每日赠送（按周一到账）。
        if prod.weekTotal > 0 { parts.append("每周赠送 \(prod.weekTotal) 墨点") }
        if prod.signinBonus > 1 { parts.append("签到 ×\(prod.signinBonus)") }
        let text = parts.isEmpty ? "30 天全功能" : parts.joined(separator: " · ")
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(AE.textSecondary)
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
        let name = "AEVIS 会员"
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
            guard !order.qrContent.isEmpty else { showTip("支付链接为空，请稍后重试"); return }
            // 2.8：微信 / 支付宝都进同一个聚合二维码弹窗，不再跳外部浏览器。
            activePay = ActivePay(
                order: order,
                title: "开通 AEVIS 会员 · \(prod.days) 天",
                channel: channel.rawValue
            )
            showWeChatQR = true
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

                // 官方品牌标识（绿底双气泡 / 蓝底「支」），与商城页共用同一个组件
                PayChannelRow(brand: .alipay) { Task { await startPay(.alipay) } }
                PayChannelRow(brand: .wechat) { Task { await startPay(.wxpay) } }

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

    // 渠道行已收敛到 `Views/BrandMarks.swift` 的 `PayChannelRow`，这里不再本地实现。
    private var weChatQRSheet: some View {
        PayQRView(
            payment: activePay?.order.qrContent ?? "",
            title: "扫码支付 · " + (activePay?.title ?? ""),
            channel: activePay?.channel ?? "wxpay",
            aggregated: activePay?.order.hasAggregateLink ?? false
        ) {
            try await verifyActivePay()
        } onPaid: { result in
            onPaid(result)
        }
        .environmentObject(session)
        .presentationDetents([.fraction(0.78)])
        .glassSheetBackground()
        // 支付半屏不许下滑关闭（PayQRView 内部也有一次，双保险）
        .interactiveDismissDisabled()
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
