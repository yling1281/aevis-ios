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
    /// 「用量提升」入口：由 MainTabView 注入，跳套餐页 MemberView
    var onBuyQuota: (() -> Void)? = nil
    /// 「按次计费」入口：由 MainTabView 注入，跳商城按次 tab
    var onPerUse: (() -> Void)? = nil
    /// 广场入口：由 MainTabView 注入，用右滑全屏二级菜单承载（2.8）；nil 时用本页 sheet 兜底。
    var onPlaza: ((Int) -> Void)? = nil
    /// 用量卡是否展开（标题旁 chevron 可折叠）
    @State private var usageExpanded = true
    @State private var showShop = false        // 仅在 onShop == nil 时用的占位
    @State private var showMember = false      // 仅在 onMember == nil 时用的占位
    @State private var showPlaza = false       // 人设/表情包广场（本页内 sheet 即可）
    @State private var plazaTab = 0
    @State private var showCheckIn = false     // 每日签到（2.8）
    @State private var tip = ""
    @State private var serviceExpanded = true

    /// 真实用量（2026-11-24）：本周额度百分比 + 墨点余额 / 可聊条数。
    /// 取不到就是 nil，卡片显示「—」—— **不写死 92%、不按 /35 估算**。
    @State private var quota: APIClient.QuotaState? = nil
    /// 用量条上小狗徽章的滑动进度（0 = 最左，= leftPct 时到位）。进页面时从 0 滑过去。
    @State private var mascotProgress: CGFloat = 0
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
                // 开屏元素依次轻微上跳（用户要求）：0.05s 递进，不是整块一起淡入
                greeting.staggerIn(0)
                usageCard.staggerIn(1)
                sectionHeader("服务", expanded: $serviceExpanded).staggerIn(2)
                if serviceExpanded { serviceGrid.staggerIn(3) }
                if !tip.isEmpty { tipBanner }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            // 底部留 TabBar 高度 + 安全区
            .padding(.bottom, 96)
        }
        .background(Color.clear)   // 背景统一由 AppBackgroundHost 最底层提供，这里不能再铺不透明底
        // 首页白膜压得最重（参考图 ≈0.86）：照片只剩极淡纹理，整体读起来是暖白
        .appBackgroundIntensity(AEGlass.veilHome)
        .onAppear {
            // 2.8 冷启动首帧：先同步读硬缓存，用量 / 余额 / 头像不转圈。
            // 读不到就保持占位，随后 Task 走网络；失败时也还有上次的值。
            if let raw = APIClient.cachedJSON(.quotaState, scope: APIClient.cacheScope) {
                quota = APIClient.parseQuotaState(raw)
            }
            if let raw = APIClient.cachedJSON(.pointsHome, scope: APIClient.cacheScope) {
                points = APIClient.parsePointsHome(raw)
            }
            if let raw = APIClient.cachedJSON(.memberState, scope: APIClient.cacheScope) {
                let d = (raw["data"] as? [String: Any]) ?? raw
                let nick = (d["nickname"] as? String) ?? (raw["nickname"] as? String) ?? ""
                let pic = (d["avatar"] as? String) ?? (raw["avatar"] as? String) ?? ""
                if !nick.isEmpty { nickname = nick }
                if !pic.isEmpty { avatarPath = pic }
            }
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
        .sheet(isPresented: $showCheckIn) {
            CheckInView()
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

            // 签到入口（2.8）：主页可见，点开是独立页，不占服务宫格的位置。
            Button { showCheckIn = true } label: {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 30, height: 30)
                    .background(AE.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("每日签到")
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
            CachedRemoteImage(url: avatarURL, scope: "user:\(session.email)") {
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
        // 展示层归一化：不管上游给英文还是中文，屏幕上只可能是这 10 类中文之一，
        // 认不出来显示「未知」，绝不把 Sunny/Cloudy 原样丢给用户。
        let info = WeatherText.resolve(w.descCN)
        return VStack(alignment: .trailing, spacing: 1) {
            if !w.place.isEmpty {
                Text(w.place)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                Image(systemName: info.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text("\(info.text) \(w.tempC)°")
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
        .accessibilityLabel("\(w.place) \(info.text) \(w.tempC) 度" + (weatherAgeText.map { "，\($0)" } ?? ""))
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

    // 天气图标并入 `WeatherText.symbol(_:)`（展示层统一归一化后再取图标），
    // 这里不再单独维护一份映射表，避免两处映射不一致。

    // MARK: - 用量额度卡
    //
    // 2026-11-25 按用户参考图重排内部结构（形态照图，不含首页 IA 改动）：
    // 头部「17pt semibold 标题 + chevron」与「两枚 34pt 黄色胶囊」同一行 →
    // 52pt heavy 大数字（% 18pt 基线对齐）+ 右侧「已用 N%」13pt →
    // 9pt 进度条（轨道 #E6E6E8，填充 #BFD9F5→#7EA8DC，圆头）+ 26pt 白底猫脸徽章（上下各溢出 8pt，
    // 这是整张卡的辨识点）→ 底部 13pt 灰字「还有 N 条 / M月D日 HH:MM 重置」。
    // 材质一律走 `usageCardGlass()`，别在这里手写。

    /// 参考图主文字色（近黑，不用纯黑）
    private var usageInk: Color {
        Color.adaptive(dark: AE.textPrimary, light: Color.hex(0x1A1A1C))
    }

    /// 参考图次要文字色 #8A8A8E（深色模式提亮，保持同层级对比）
    private var usageGray: Color {
        Color.adaptive(dark: Color.hex(0xB4B4B9), light: Color.hex(0x8A8A8E))
    }

    /// 进度条轨道 #E6E6E8
    private var usageTrack: Color {
        Color.adaptive(dark: Color.hex(0x3A3A3E), light: Color.hex(0xE6E6E8))
    }

    /// 进度条填充：参考图 #BFD9F5 → #7EA8DC
    private var usageFill: LinearGradient {
        LinearGradient(
            colors: [Color.hex(0xBFD9F5), Color.hex(0x7EA8DC)],
            startPoint: .leading, endPoint: .trailing
        )
    }

    /// 用户要求的「已用 N%」：只显示服务端 quota 的真实百分比，不写死。
    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 行 1：标题 + chevron ｜ 右侧两枚黄色胶囊
            HStack(spacing: 8) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { usageExpanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text("用量额度")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(usageInk)
                        Image(systemName: usageExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(usageGray)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(usageExpanded ? "收起用量额度" : "展开用量额度")

                Spacer(minLength: 4)

                // 会员 / 商城入口按服务端开关开放；关掉时这两枚胶囊直接不出现。
                if AevisHosts.featureEnabled("member") {
                    Button { onBuyQuota?() } label: {
                        quotaCapsule("用量提升", symbol: "crown.fill", showNew: false)
                    }
                    .buttonStyle(.plain)
                }
                if AevisHosts.featureEnabled("shop") {
                    Button { onPerUse?() } label: {
                        quotaCapsule("按次计费", symbol: nil, showNew: true)
                    }
                    .buttonStyle(.plain)
                }
            }

            if usageExpanded {
                // 行 2：52pt heavy 大数字 + 18pt 百分比（基线对齐）｜ 右侧「已用 N%」
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let q = quota {
                        AnimatedNumber(
                            value: q.leftPct,
                            font: .system(size: 52, weight: .heavy, design: .rounded),
                            color: usageInk
                        )
                        Text("%")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(usageInk)
                        Spacer(minLength: 8)
                        Text("已用 \(q.percent)%")
                            .font(.system(size: 13))
                            .foregroundStyle(usageGray)
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .font(.system(size: 52, weight: .heavy, design: .rounded))
                            .foregroundStyle(usageInk)
                        Spacer(minLength: 8)
                        Text("已用 —")
                            .font(.system(size: 13))
                            .foregroundStyle(usageGray)
                    }
                }

                // 行 3：9pt 进度条（圆头）+ 头部白色猫脸徽章
                // 徽章 26pt、轨道 9pt → 上下各溢出 8.5pt，正是参考图那个「顶出来」的效果。
                // 2026-11-26 用户要求：进页面时小狗要从最左边滑到当前用量位置，不是静态出现的。
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let target = CGFloat(min(max(quota?.leftPct ?? 0, 0), 100))
                    let animated = width * mascotProgress / 100
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(usageTrack)
                            .frame(height: 9)
                        if quota != nil {
                            Capsule()
                                .fill(usageFill)
                                .frame(width: max(animated, 9), height: 9)
                            mascotBadge(hasQuota: quota?.hasQuota ?? true)
                                // 徽章中心压在填充头部；两端各夹一次，避免溢出卡片内边距
                                .offset(x: min(max(animated - 13, 0), width - 26))
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .onAppear { slideMascot(to: target) }
                    // 最低支持 iOS 16：不能用 iOS 17 的 `onChange(of:initial:_:)` 双参签名，
                    // 走单参旧签名（Xcode 16 会提示 deprecated，但仍是 iOS16 唯一可用写法）。
                    .onChange(of: target) { newValue in slideMascot(to: newValue) }
                }
                .frame(height: 26)

                // 行 4：底部 13pt 灰字，左右两端
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(remainingMessagesLine)
                        .font(.system(size: 13))
                        .foregroundStyle(usageGray)
                    Spacer(minLength: 6)
                    if let reset = resetTimeLine {
                        Text(reset)
                            .font(.system(size: 13))
                            .foregroundStyle(usageGray)
                            .lineLimit(1)
                    }
                }

                Divider().opacity(0.35)
                // 墨点是独立单位，单独一行，不参与本周额度计算
                balanceRow
            }
        }
        .padding(16)
        // 「有点透但不是特别透」：ultraThinMaterial + 白 0.62（暗色 黑 0.34），无描边 + 极淡阴影。
        // 见 `GlassComponents.UsageCardGlass`，别在这里手写材质。
        .usageCardGlass()
    }

    /// 进度条头部的白底猫脸徽章（26pt 白片 + 极淡阴影，猫脸 18pt）。
    /// 参考图里它上下各溢出 8pt，是这张卡最容易被认出来的特征 —— 别省。
    private func mascotBadge(hasQuota: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Color.white)
                .frame(width: 26, height: 26)
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 1)
            AevisMascotMark(pose: hasQuota ? .front : .sleep, size: 18)
        }
        .accessibilityHidden(true)
    }

    /// 让小狗徽章从最左边滑到当前用量位置（2026-11-26 用户要求有动效，不要静态出现）。
    /// 减弱动效时直接到位。
    private func slideMascot(to pct: CGFloat) {
        if UIAccessibility.isReduceMotionEnabled {
            mascotProgress = pct
            return
        }
        withAnimation(.spring(response: 1.05, dampingFraction: 0.78).delay(0.12)) {
            mascotProgress = pct
        }
    }

    /// 黄底胶囊（2.8 按用户反馈缩小）：底 `#F5DC96` @0.85，高 26pt（原 34），
    /// 12pt 文字（原 14）、12pt 图标、横向留白 9pt（原 12）。「按次计费」保留 NEW 红标。
    private func quotaCapsule(_ text: String, symbol: String?, showNew: Bool) -> some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
            if showNew {
                Text("NEW")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.hex(0xE5484D), in: Capsule())
            }
        }
        .foregroundStyle(AE.accentDeep)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.hex(0xF5DC96).opacity(0.85), in: Capsule())
        .contentShape(Capsule())
    }

    /// 剩余消息条数。优先级（2026-11-25 修正，顺序别写反）：
    /// 1. **`quota.estMessages`** —— 服务端按「本周剩余额度」折的条数，会员和免费用户都对；
    /// 2. `points.estMessages` —— 墨点余额 ÷ 均价，只对**有余额**的用户有意义；
    /// 3. `freeMessageBaseline × leftPct` —— 前两个都没有时的本地估算。
    ///
    /// 旧实现把 2 放在 1 前面，导致免费用户（余额 0）首页恒显示「还有 0 条」，
    /// 而他实际还有整周的免费额度。
    private var remainingMessagesLine: String {
        if let q = quota, q.estMessages > 0 {
            return "您大约还有 \(q.estMessages.formatted()) 条消息额度"
        }
        if let p = points, p.estMessages > 0 {
            return "您大约还有 \(p.estMessages.formatted()) 条消息额度"
        }
        if let q = quota {
            let n = Int((Double(APIClient.freeMessageBaseline) * Double(q.leftPct) / 100.0).rounded())
            return "您大约还有 \(n) 条消息额度"
        }
        return "您大约还有 — 条消息额度"
    }

    /// 重置时间只认服务端下发字段；没有就不显示这一行，绝不写死日期。
    private var resetTimeLine: String? {
        guard let raw = quota?.resetAt, !raw.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M'月'd'日' HH:mm"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
            ?? Self.plainDateFormatter.date(from: raw)
        guard let d = date else { return nil }
        return f.string(from: d) + " 重置"
    }

    private static let plainDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 墨点余额：独立单位，只讲墨点，不再和本周额度混在一行。
    /// 拿不到就「—」，不显示 0、不用 /35 估算。
    ///
    /// 2026-11-25：余额为 0 时不再显示「约还能聊 0 条」—— 免费用户本来就是 0，
    /// 紧贴着上一行「您大约还有 15 条消息额度」写「约还能聊 0 条」，读起来自相矛盾。
    private var balanceLine: String {
        guard let points else { return "墨点余额 —（独立单位，不计入本周额度）" }
        guard points.points > 0 else { return "墨点余额 0（独立单位，不计入本周额度）" }
        return "墨点余额 \(points.points.formatted()) · 约还能聊 \(points.estMessages.formatted()) 条（独立单位）"
    }

    /// 余额行：数值走 `AnimatedNumber`，刷新时逐帧滚动；拿不到 / 为 0 时保留原文案。
    @ViewBuilder
    private var balanceRow: some View {
        if let points, points.points > 0 {
            HStack(spacing: 4) {
                Text("墨点余额")
                AnimatedNumber(
                    value: points.points,
                    font: .system(size: 11.5, weight: .semibold, design: .rounded),
                    color: usageGray
                )
                Text("· 约还能聊 \(points.estMessages) 条（独立单位）")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(usageGray)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        } else {
            Text(balanceLine)
                .font(.system(size: 11.5))
                .foregroundStyle(usageGray)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// 本周额度百分比口径（与墨点彻底分开）
    private var quotaPercentLine: String {
        if let quota {
            return "本周已用 \(quota.percent)% · 剩余 \(quota.leftPct)%"
        }
        if session.token == nil { return "登录后可查看本周额度百分比" }
        return "额度百分比暂时取不到，下拉可重试"
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
        let label: String
        let symbol: String
        let color: Color
        /// 用 label 当稳定 id：`serviceItems` 是计算属性，用 UUID 会让每次重绘都重建格子。
        var id: String { label }
    }

    /// 只放真正能跳的入口，且逐项受服务端开关约束：
    /// 商城 → shop / 会员 → member / 人设广场 → plaza / 表情包 → stickers。
    /// 默认全关（服务端不下命令），此时服务宫格为空 —— 这是预期行为。
    private var serviceItems: [HomeEntry] {
        var items: [HomeEntry] = []
        if AevisHosts.featureEnabled("shop") {
            items.append(HomeEntry(label: "商城", symbol: "bag.fill", color: Color.hex(0xE8913F)))
        }
        if AevisHosts.featureEnabled("member") {
            items.append(HomeEntry(label: "会员", symbol: "crown.fill", color: Color.hex(0xE5484D)))
        }
        if AevisHosts.featureEnabled("plaza") {
            items.append(HomeEntry(label: "人设广场", symbol: "person.2.fill", color: Color.hex(0x6C7BC4)))
        }
        if AevisHosts.featureEnabled("stickers") {
            items.append(HomeEntry(label: "表情包", symbol: "face.smiling.fill", color: Color.hex(0x48A88B)))
        }
        return items
    }

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
                plazaTab = 0
                if let onPlaza { onPlaza(0) } else { showPlaza = true }
            case "表情包":
                plazaTab = 1
                if let onPlaza { onPlaza(1) } else { showPlaza = true }
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
