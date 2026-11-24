import SwiftUI
import CoreLocation

/// 主页：用量额度卡 + 服务入口（商城 → ShopView、会员 → MemberView、
/// 人设广场 / 表情包广场 → PlazaView，均为独立页面，不串返回层级）。
/// 用量卡是真实数据：本周额度百分比来自 `GET /v1/quota/state`，
/// 墨点余额 / 还能聊多少条来自 `GET /v1/points`；未登录或请求失败一律显示「—」，不写死数字。
/// 整体可滚动（主页允许滚，登录页才禁止）；底部留 TabBar 高度 padding。
/// 卡片全部磨砂（复用 GlassComponents），入口用彩色圆角图标底（按用户截图）。
/// 没做的功能不加按钮 —— 用户明确要求「目前没有的功能先不加按钮」。
struct HomeView: View {
    @EnvironmentObject private var session: Session

    /// 商城 / 会员入口回调：由 MainTabView 注入以全屏拉起对应页面；单独预览时为 nil 用内部占位。
    var onShop: (() -> Void)? = nil
    var onMember: (() -> Void)? = nil
    @State private var showShop = false        // 仅在 onShop == nil 时用的占位
    @State private var showMember = false      // 仅在 onMember == nil 时用的占位
    @State private var showPlaza = false       // 人设/表情包广场（本页内 sheet 即可）
    @State private var plazaTab = 0
    @State private var tip = ""
    @State private var serviceExpanded = true

    /// 真实用量（2026-11-24）：本周额度百分比 + 墨点余额 / 可聊条数。
    /// 取不到就是 nil，卡片显示「—」—— **不写死 92%、不按 /35 估算**。
    @State private var quota: APIClient.QuotaState? = nil
    @State private var points: APIClient.PointsHome? = nil

    /// 问候区（2026-11-24）：昵称 / 头像来自 `/v1/me`，天气来自 wttr.in（定位优先，南昌兜底）。
    /// 全部默认为空 —— 拿不到就不显示，不用狗 logo 冒充用户头像。
    @State private var nickname = ""
    @State private var avatarPath = ""
    @State private var weather: APIClient.WeatherNow? = nil
    /// 天气的获取时间（持久化），用于「更新于 X 分钟前」
    @State private var weatherAt: Date? = nil

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
        .background(Color.clear)   // 背景统一由 MainTabView 最底层提供，这里不能再铺不透明底
        .onAppear {
            // 冷启动先显示上次的天气（不等定位/网络），再拉最新数据
            restoreLastWeather()
            // 用量额度优先级最高，必须独立 Task。
            // 之前是 `await loadGreeting(); await loadUsage()` 串行——loadGreeting 内含
            // 1.5s 延迟 + 最长 5s 定位 + 两次天气请求（最坏 10s+），
            // 导致进主页好几秒用量卡都是「—」，用户以为"卡住 / 啥都没有"。
            // 拆成两个独立 Task 后额度 ~0.3s 就显示，不被问候/天气链路拖住。
            Task { await loadUsage() }
            Task { await loadGreeting() }
        }
        .refreshable {
            // 下拉刷新：额度与问候/天气并发，谁先回来谁先显示，不让天气拖住额度
            async let usage: Void = loadUsage()
            async let greeting: Void = loadGreeting(refreshWeather: true)
            _ = await (usage, greeting)
        }
        .sheet(isPresented: $showShop) {
            // 仅预览态（无 MainTabView 注入回调）时用；真机走 fullScreenCover
            VStack(spacing: 14) {
                Image(systemName: "bag").font(.system(size: 34)).foregroundStyle(AE.accent)
                Text("商城即将上线").font(.system(size: 18, weight: .semibold))
                Text("第 2 轮接入五大分区").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                Button("知道了") { showShop = false }.foregroundStyle(AE.accent)
            }
            .padding(30)
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showMember) {
            VStack(spacing: 14) {
                Image(systemName: "crown").font(.system(size: 34)).foregroundStyle(AE.accent)
                Text("会员页请在主页入口打开").font(.system(size: 18, weight: .semibold))
                Button("知道了") { showMember = false }.foregroundStyle(AE.accent)
            }
            .padding(30)
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPlaza) {
            PlazaView(initialTab: plazaTab)
                .environmentObject(session)
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

    /// 头像：磁盘硬缓存优先（`CachedRemoteImage`），没有缓存才显示渐变圆底 + 首字占位；
    /// 后台带 ETag 条件请求，服务器说变了才换图（断网一直用旧图）。
    @ViewBuilder
    private var avatarView: some View {
        if let avatarURL {
            CachedRemoteImage(url: avatarURL) {
                avatarPlaceholder
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

    /// 天气小胶囊：城市名（定位得到的 `nearest_area`，南昌兜底时是「南昌」）/
    /// 「多云 18°」/ 第三行小字「更新于 X 分钟前」（刚刷新完不显示）。
    /// 城市名拿不到就少一行，不留空行。
    private func weatherChip(_ w: APIClient.WeatherNow) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if !w.place.isEmpty {
                Text(w.place)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Image(systemName: weatherSymbol(w.descCN))
                    .font(.system(size: 11, weight: .medium))
                Text("\(w.descCN) \(w.tempC)°")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(AE.accent)

            if let age = weatherAgeText {
                Text(age)
                    .font(.system(size: 8.5))
                    .foregroundStyle(AE.textSecondary.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(AE.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(w.place) \(w.descCN) \(w.tempC) 度" + (weatherAgeText.map { "，\($0)" } ?? ""))
    }

    /// 「更新于 X 分钟前」：<1 分钟不显示（刚刷新完没必要提醒），超过 1 小时按小时/天换算
    private var weatherAgeText: String? {
        guard let weatherAt else { return nil }
        let seconds = Date().timeIntervalSince(weatherAt)
        guard seconds >= 60 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "更新于 \(minutes) 分钟前" }
        let hours = minutes / 60
        return hours < 24 ? "更新于 \(hours) 小时前" : "更新于 \(hours / 24) 天前"
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
        // 两个接口并发：原来串行时 points 一慢就把 quota 一起拖住。
        async let q: APIClient.QuotaState? = try? APIClient.quotaState(token: token)
        async let p: APIClient.PointsHome? = try? APIClient.pointsHome(token: token)
        let quotaValue = await q
        let pointsValue = await p
        await MainActor.run {
            withAnimation(.easeOut(duration: 0.25)) {
                quota = quotaValue
                points = pointsValue
            }
        }
    }

    // MARK: - 问候区数据

    /// 昵称 / 头像（`/v1/me`）+ 天气（定位坐标查 wttr.in，失败回落南昌）。
    /// 顺序刻意安排成「先人后天气」：昵称/头像先渲染，天气延后 1.5 秒再去定位，
    /// 避免用户一进主页就被权限弹窗吓到；下拉刷新不再延迟。
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

        // 首屏延迟 1.5 秒再请求定位（权限框不要在冷启动瞬间弹）
        if !refreshWeather {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // 主路径：定位 → 按坐标查天气（会带出城市名）
        var w: APIClient.WeatherNow? = nil
        if let coord = await OneShotLocation.shared.currentCoordinate(timeout: 5) {
            w = try? await APIClient.weather(
                lat: coord.latitude, lon: coord.longitude, force: refreshWeather)
        }
        // 定位被拒 / 超时 / 定位失败 / 按坐标查天气失败 → 回落南昌（保持旧行为，不变成不显示）
        if w == nil {
            w = try? await APIClient.weatherNanchang(force: refreshWeather)
        }
        if let w {
            // 同时落盘：下次冷启动直接显示这条，不用等定位
            await MainActor.run { rememberWeather(w) }
        }
    }

    // MARK: - 天气持久化（冷启动先显示上次的）

    private static let lastWeatherKey = "aevis.weather.last.v1"

    /// 冷启动/切回主页时先把上次的天气摆上去（含时间戳 → 显示「更新于 X 分钟前」）。
    /// 已经有本次会话拿到的天气就不覆盖（切 tab 回来时内存里那份更新）。
    private func restoreLastWeather() {
        guard weather == nil else { return }
        guard let d = UserDefaults.standard.dictionary(forKey: Self.lastWeatherKey),
              let t = d["temp"] as? Int,
              let desc = d["desc"] as? String, !desc.isEmpty else { return }
        let at = Date(timeIntervalSince1970: (d["at"] as? Double) ?? 0)
        weather = APIClient.WeatherNow(tempC: t, descCN: desc, place: (d["place"] as? String) ?? "")
        // 时间戳坏了就不显示「更新于」，但天气本身仍然摆出来
        weatherAt = at.timeIntervalSince1970 > 0 ? at : nil
    }

    /// 每次成功拿到天气都写盘：`{temp, desc, place, at}`。断网时下次启动仍能显示。
    private func rememberWeather(_ w: APIClient.WeatherNow) {
        let now = Date()
        weather = w
        weatherAt = now
        UserDefaults.standard.set(
            ["temp": w.tempC, "desc": w.descCN, "place": w.place, "at": now.timeIntervalSince1970],
            forKey: Self.lastWeatherKey
        )
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

    /// 只放真正能跳的入口：商城 / 会员 / 人设广场 / 表情包广场；没做的功能不加按钮。
    private let serviceItems: [HomeEntry] = [
        HomeEntry(label: "商城", symbol: "bag.fill", color: Color.hex(0xE8913F)),
        HomeEntry(label: "会员", symbol: "crown.fill", color: Color.hex(0xE5484D)),
        HomeEntry(label: "人设广场", symbol: "person.2.fill", color: Color.hex(0x6C7BC4)),
        HomeEntry(label: "表情包", symbol: "face.smiling.fill", color: Color.hex(0x48A88B)),
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
            switch item.label {
            case "商城":
                if let onShop { onShop() } else { showShop = true }
            case "会员":
                if let onMember { onMember() } else { showMember = true }
            case "人设广场":
                plazaTab = 0; showPlaza = true
            case "表情包":
                plazaTab = 1; showPlaza = true
            default:
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

// MARK: - 一次性定位（只为天气）

/// 单次定位封装：`requestLocation()` 只取一次坐标就停，不做持续定位（省电）。
///
/// 几个必须这么写的点：
/// - `CLLocationManager` 必须在主线程创建并**强引用**着，否则回调不触发 —— 所以用单例，
///   不放在 View 的 `@State`（视图重建会重建 manager）；
/// - 首次 `authorizationStatus == .notDetermined` 时先 `requestWhenInUseAuthorization()`，
///   授权结果由 `locationManagerDidChangeAuthorization` 回来后**再** `requestLocation()`；
/// - 5 秒超时兜底：用户不点弹窗 / 关掉定位服务时不会把 UI 卡住，直接返回 nil 交给调用方降级；
/// - 坐标只保存在内存里（10 分钟），**不写 UserDefaults、不上传**，仅用于拼 wttr.in URL。
private final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    static let shared = OneShotLocation()

    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer   // 只看城市天气，公里级足够且省电
        return m
    }()

    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// 本次请求的定位超时（授权解决后按它计时）
    private var activeTimeout: TimeInterval = 5
    /// 内存级缓存（10 分钟）：避免切 tab 回来重复定位、重复弹权限
    private var lastCoordinate: CLLocationCoordinate2D?
    private var lastAt: Date?

    /// 取一次当前坐标。授权被拒 / 5 秒超时 / 定位失败都返回 nil，不抛错。
    func currentCoordinate(timeout seconds: TimeInterval = 5) async -> CLLocationCoordinate2D? {
        if let c = lastCoordinate, let at = lastAt, Date().timeIntervalSince(at) < 600 {
            return c
        }
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                // 已有请求在等：本次直接放弃（调用方会回落南昌），避免两次 requestLocation 抢回调
                guard self.continuation == nil else {
                    cont.resume(returning: nil)
                    return
                }
                self.continuation = cont
                self.activeTimeout = seconds

                switch self.manager.authorizationStatus {
                case .notDetermined:
                    // 等用户点系统权限弹窗：这里放宽到 20 秒（读弹窗要时间），
                    // 授权一回来会重置成 5 秒的「定位」超时，见 delegate。
                    self.startTimeout(max(seconds, 20))
                    self.manager.requestWhenInUseAuthorization()
                case .authorizedWhenInUse, .authorizedAlways:
                    self.startTimeout(seconds)
                    self.manager.requestLocation()
                default:
                    self.startTimeout(seconds)
                    self.finish(nil)                               // 已拒绝 / 受家长控制等
                }
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard continuation != nil else { return }
            manager.requestLocation()
            startTimeout(activeTimeout)  // 授权已解决，接下来只等定位本身（默认 5 秒）
        case .notDetermined:
            break                       // 首次设置 delegate 就会回调一次，等用户选择
        default:
            finish(nil)                 // denied / restricted：立刻降级到南昌
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    // MARK: 内部

    /// 统一收口：只 resume 一次 continuation，并清掉超时任务。
    private func finish(_ coord: CLLocationCoordinate2D?) {
        DispatchQueue.main.async {
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            if let c = coord {
                self.lastCoordinate = c
                self.lastAt = Date()
            }
            guard let cont = self.continuation else { return }
            self.continuation = nil
            cont.resume(returning: coord)
        }
    }

    private func startTimeout(_ seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.finish(nil)
        }
    }
}
