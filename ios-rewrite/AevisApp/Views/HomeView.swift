import SwiftUI

/// 主页：用量额度卡 + 服务入口（只放真正能跳的：商城 / 会员，都进 ShopView）。
/// 用量卡是真实数据：本周额度百分比来自 `GET /v1/quota/state`，
/// 墨点余额 / 还能聊多少条来自 `GET /v1/points`；未登录或请求失败一律显示「—」，不写死数字。
/// 整体可滚动（主页允许滚，登录页才禁止）；底部留 TabBar 高度 padding。
/// 卡片全部磨砂（复用 GlassComponents），入口用彩色圆角图标底（按用户截图）。
/// 没做的功能不加按钮 —— 用户明确要求「目前没有的功能先不加按钮」。
struct HomeView: View {
    @EnvironmentObject private var session: Session

    /// 商城入口回调：由 MainTabView 注入以全屏拉起 ShopView；单独预览时为 nil 用内部占位。
    var onShop: (() -> Void)? = nil
    @State private var showShop = false        // 仅在 onShop == nil 时用的占位
    @State private var tip = ""
    @State private var serviceExpanded = true

    /// 真实用量（2026-11-24）：本周额度百分比 + 墨点余额 / 可聊条数。
    /// 取不到就是 nil，卡片显示「—」—— **不写死 92%、不按 /35 估算**。
    @State private var quota: APIClient.QuotaState? = nil
    @State private var points: APIClient.PointsHome? = nil

    /// 问候区（2026-11-24）：昵称 / 头像来自 `/v1/me`，天气来自 wttr.in（10 分钟缓存）。
    /// 全部默认为空 —— 拿不到就不显示，不用狗 logo 冒充用户头像。
    @State private var nickname = ""
    @State private var avatarPath = ""
    @State private var weather: APIClient.WeatherNow? = nil

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                greeting
                usageCard
                sectionHeader("服务", expanded: $serviceExpanded)
                if serviceExpanded { serviceGrid }
                if !tip.isEmpty { tipBanner }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            // 底部留 TabBar 高度 + 安全区
            .padding(.bottom, 96)
        }
        .background(AppBackground())
        .onAppear {
            // 进页面 / 从聊天详情返回 / 切回本 tab 都重新拉一次（不做轮询）
            Task {
                await loadGreeting()
                await loadUsage()
            }
        }
        .refreshable {
            // 下拉刷新：天气跳过 10 分钟缓存，昵称/头像/额度一起重取
            await loadGreeting(refreshWeather: true)
            await loadUsage()
        }
        .sheet(isPresented: $showShop) {
            // 第 2 轮接 ShopView；这轮先明确提示，不假装能进
            VStack(spacing: 14) {
                Image(systemName: "bag").font(.system(size: 34)).foregroundStyle(AE.accent)
                Text("商城即将上线").font(.system(size: 18, weight: .semibold))
                Text("第 2 轮接入五大分区").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                Button("知道了") { showShop = false }.foregroundStyle(AE.accent)
            }
            .padding(30)
            .presentationDetents([.medium])
        }
    }

    // MARK: - 顶部问候

    private var greeting: some View {
        HStack(spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 3) {
                Text(greetingTitle)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text("今天想聊点什么？")
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
            }

            Spacer(minLength: 4)

            // 天气拿不到就整块不显示（不放假数据）
            if let weather, !weather.descCN.isEmpty {
                weatherChip(weather)
            }
        }
    }

    /// 时段问候：5–11 早上好 / 11–13 中午好 / 13–18 下午好 / 18–5 晚上好。
    /// 有昵称就拼成「晚上好，阿狸」；没昵称只显示时段问候（不硬塞「你」这种别扭称呼）。
    private var periodGreeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case 5..<11: return "早上好"
        case 11..<13: return "中午好"
        case 13..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var greetingTitle: String {
        nickname.isEmpty ? periodGreeting : "\(periodGreeting)，\(nickname)"
    }

    // MARK: - 头像（用户自己的）

    /// 头像：有图走 AsyncImage，空/失败 → 渐变圆底 + 首字占位（与 ChatView / ChatListView 同一套）。
    @ViewBuilder
    private var avatarView: some View {
        if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    avatarPlaceholder
                default:
                    avatarPlaceholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
            .shadow(color: AE.shadowColor, radius: 4, y: 2)
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [AE.accentLift, AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(String(placeholderName.prefix(1)))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 44, height: 44)
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
        .shadow(color: AE.shadowColor, radius: 4, y: 2)
    }

    /// 占位首字：昵称 → 「我」（和 ChatView「我」的气泡占位一致）
    private var placeholderName: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "我" : nickname
    }

    /// 头像地址：Session.avatar（登录/冷启动已同步）优先，其次本页 `/v1/me` 取到的那份。
    /// 相对路径拼当前线路 base；空或拼不出合法 URL → nil（走占位）。
    private var avatarURL: URL? {
        let fromSession = session.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = fromSession.isEmpty
            ? avatarPath.trimmingCharacters(in: .whitespacesAndNewlines)
            : fromSession
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        return URL(string: s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s)
    }

    /// 天气小胶囊：「多云 18°」
    private func weatherChip(_ w: APIClient.WeatherNow) -> some View {
        HStack(spacing: 4) {
            Image(systemName: weatherSymbol(w.descCN))
                .font(.system(size: 11, weight: .medium))
            Text("\(w.descCN) \(w.tempC)°")
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(AE.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(AE.accentSoft, in: Capsule())
        .accessibilityLabel("南昌 \(w.descCN) \(w.tempC) 度")
    }

    private func weatherSymbol(_ desc: String) -> String {
        if desc.contains("雷") { return "cloud.bolt.rain.fill" }
        if desc.contains("雪") { return "cloud.snow.fill" }
        if desc.contains("雨") { return "cloud.rain.fill" }
        if desc.contains("雾") { return "cloud.fog.fill" }
        if desc.contains("阴") { return "cloud.fill" }
        if desc.contains("多云") { return "cloud.sun.fill" }
        if desc.contains("晴") { return "sun.max.fill" }
        return "cloud.fill"
    }

    // MARK: - 用量额度卡

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本周额度")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                Spacer()
                // 两个小胶囊
                HStack(spacing: 6) {
                    capsule("用量提升")
                    capsule("按次计费")
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        if let quota {
                            AnimatedNumber(
                                value: quota.percent,
                                font: .system(size: 34, weight: .bold, design: .rounded),
                                color: AE.textPrimary, suffix: "%"
                            )
                        } else {
                            // 没数据就是「—」，不回落到 92%
                            Text("—")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(AE.textPrimary)
                        }
                        Text("已用")
                            .font(.system(size: 12))
                            .foregroundStyle(AE.textSecondary)
                    }
                    Text(balanceLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                // 额度卡大图：无底矢量狗头（宽 96pt，实际高度 ≈ 80pt）。
                // 本周额度用完时换成打盹姿态（.sleep），比干巴巴的「—」更有情绪；
                // 纯装饰，不参与无障碍朗读。
                AevisMascotMark(
                    pose: quota?.hasQuota == false ? .sleep : .front,
                    size: 96
                )
                .accessibilityHidden(true)
            }

            // 进度条（没拿到数据就只画空槽，不画假进度；狗头已移到右上大图）
            ZStack(alignment: .leading) {
                Capsule().fill(AE.textPrimary.opacity(0.08)).frame(height: 8)
                GeometryReader { geo in
                    let pct = CGFloat(quota?.percent ?? 0)
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.hex(0xFFD66B), AE.brandPurple],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * min(max(pct, 0), 100) / 100, height: 8)
                }
                .frame(height: 8)
            }

            Text(quotaLine)
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)
        }
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
    }

    /// 墨点余额 + 还能聊多少条：拿不到就「—」，不显示 0、不用 /35 估算
    private var balanceLine: String {
        guard let points else { return "墨点 — · 约还能聊 — 条" }
        return "墨点 \(points.points.formatted()) · 约还能聊 \(points.estMessages.formatted()) 条"
    }

    private var quotaLine: String {
        if let quota {
            return quota.hasQuota
                ? "本周还剩 \(quota.leftPct)% 额度 · 用完后可在「商城」补充"
                : "本周额度已用完，可到「商城」补充"
        }
        if session.token == nil { return "登录后可查看本周额度" }
        return "额度暂时取不到，下拉可重试"
    }

    // MARK: - 真实用量数据

    /// 拉本周额度（只给百分比）+ 墨点余额 / 可聊条数。
    /// 未登录或任一请求失败 → 对应项置 nil，卡片显示「—」；绝不回落到写死的数字。
    private func loadUsage() async {
        guard let token = session.token, !token.isEmpty else {
            await MainActor.run {
                quota = nil
                points = nil
            }
            return
        }
        let q = try? await APIClient.quotaState(token: token)
        let p = try? await APIClient.pointsHome(token: token)
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.25)) {
                quota = q
                points = p
            }
        }
    }

    // MARK: - 问候区数据

    /// 昵称 / 头像（`/v1/me`）+ 天气（wttr.in，10 分钟缓存）。
    /// 顺序：先取本服务器的昵称（快、视觉主体），再取外网天气；各自失败互不影响，也不放任何假数据。
    private func loadGreeting(refreshWeather: Bool = false) async {
        if let token = session.token, !token.isEmpty,
           let json = try? await APIClient.me(token: token) {
            let d = (json["data"] as? [String: Any]) ?? json
            let nick = (d["nickname"] as? String) ?? (json["nickname"] as? String) ?? ""
            let av = (d["avatar"] as? String) ?? (json["avatar"] as? String) ?? ""
            await MainActor.run {
                nickname = nick
                avatarPath = av
            }
        }

        // 天气：首屏可能有 3 秒超时，失败就不显示（不阻塞昵称渲染）
        if let w = try? await APIClient.weatherNanchang(force: refreshWeather) {
            await MainActor.run { weather = w }
        }
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AE.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(AE.accentSoft, in: Capsule())
    }

    // MARK: - 分区标题（可折叠）

    private func sectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 九宫格

    private struct HomeEntry: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let color: Color
        let badge: String = ""
    }

    /// 只放真正能跳的入口（商城 / 会员都进 ShopView）；没做的功能不加按钮。
    private let serviceItems: [HomeEntry] = [
        HomeEntry(label: "商城", symbol: "bag.fill", color: Color.hex(0xE8913F)),
        HomeEntry(label: "会员", symbol: "crown.fill", color: Color.hex(0xE5484D)),
    ]

    private var serviceGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
            ForEach(serviceItems) { item in
                gridCell(item)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    private func gridCell(_ item: HomeEntry) -> some View {
        Button {
            if item.label == "商城" || item.label == "会员" {
                if let onShop { onShop() } else { showShop = true }
            } else {
                showTip("「\(item.label)」即将上线")
            }
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(item.color.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(item.color)
                }
                Text(item.label)
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(AevisPressStyle(scale: 0.94))
        .accessibilityLabel(item.label)
    }

    private var tipBanner: some View {
        Text(tip)
            .font(.system(size: 12))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .transition(.opacity)
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
