import SwiftUI

/// 我 —— 微信的第四个 tab。
///
/// ## 2026-11-01 第三次修「点『我』闪退」
///
/// 前两次的判断都错了：
/// ① 第一次怪「分段 Picker 套液态玻璃」→ 去掉玻璃，照样崩；
/// ② 第二次怪 `defaultTab` 的旧值越界 → 改成自绘胶囊 + 清洗，**还是崩**。
///    （那个旧值问题是真的，但不是这个崩溃的原因。）
///
/// 所以这次不再猜「哪一行」，而是**把这一页从「漂亮」改成「不会崩」**：
///
/// - **不再用 `.aevisGlass`**。这一页是全 App 唯一「一屏叠二十多个 glassEffect」
///   的地方（每一行的图标都套一层）。玻璃图层去抓子视图绘制层这件事，
///   数量一多就可能炸，而且只在真机上炸 —— 模拟器不复现完全对得上。
/// - **不再用 `@EnvironmentObject`**。环境对象缺失是 SwiftUI 最经典的
///   「点了就崩」：`MeView` 只被 `MainTabView.page(for:)` 用，理论上继承了环境，
///   但只要有一处没注入就是必崩，而且报错只在控制台、用户完全看不到。
///   现在直接读 `PersonaStore.shared`，从根上没有「找不到环境对象」这种崩溃。
/// - **所有 Optional 都兜底**，不出现 `!`、不出现下标访问。
/// - 结构还是「一张卡 + 若干行」，只是用纯色背景 + 细描边重画。
///
/// 功能一个都没少 —— 入口、跳转、弹层全部保留。
struct MeView: View {
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var account = AccountService.shared
    @ObservedObject private var pointsService = PointsService.shared
    @ObservedObject private var inbox = InboxStore.shared

    @State private var route: SettingsRoute?
    @State private var showDisclaimer = false
    @State private var showHealth = false
    @State private var showInbox = false
    @State private var showTickets = false
    @State private var showRules = false
    @State private var showPoints = false
    @State private var showMore = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileCard

                    card {
                        row("模型接入", "bolt.horizontal", modelLine) {
                            route = SettingsRoute(focus: "model")
                        }
                        row("记忆库", "brain.head.profile", memoryLine) {
                            route = SettingsRoute(focus: "memory")
                        }
                        row("会员", "crown", memberLine) {
                            showPoints = true
                        }
                        row("站内信", "bell.badge", inboxLine, badge: inbox.unread) {
                            showInbox = true
                        }
                        row("这台设备", "iphone.gen3", deviceLine) {
                            route = SettingsRoute(focus: "device")
                        }
                        row("账号", "person.badge.key", accountLine) {
                            route = SettingsRoute(focus: "account")
                        }
                    }

                    card {
                        row("陪伴", "heart", "录音、录屏陪伴") {
                            route = SettingsRoute(focus: "companion")
                        }
                        row("外观", "paintpalette", "背景、主题色、字体") {
                            route = SettingsRoute(focus: "appearance")
                        }
                        row("AI 权限", "lock.shield", aiToolsLine) {
                            route = SettingsRoute(focus: "aitools")
                        }
                        row("积分", "star.circle", pointsLine) {
                            showPoints = true
                        }
                        row("健康", "heart.text.square", "步数、跑步走路、心率、睡眠、经期") {
                            showHealth = true
                        }
                    }

                    defaultTabCard

                    card {
                        row("怎么使用 / 规则 / 常见问题", "questionmark.circle",
                            "怎么开始用、有哪些规则、常见问题") {
                            showRules = true
                        }
                        row("帮助与反馈", "envelope", "提问题、看客服回复") {
                            showTickets = true
                        }
                        row("免责声明", "doc.text", "风险、数据存放、第三方服务") {
                            showDisclaimer = true
                        }
                        row("关于", "info.circle", "版本号") {
                            route = SettingsRoute(focus: "about")
                        }
                    }

                    moreSettings
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await account.refreshProfile()
                await inbox.refreshBadge()
            }
            .sheet(item: $route) { item in
                SettingsView(focus: item.focus)
                    .environmentObject(personaStore)
                    .environmentObject(settings)
                    .environmentObject(ChatStore.shared)
            }
            .sheet(isPresented: $showDisclaimer) { DisclaimerView() }
            .sheet(isPresented: $showHealth) { PeriodView() }
            .sheet(isPresented: $showRules) { RulesView() }
            .sheet(isPresented: $showInbox) { NavigationStack { InboxView() } }
            .sheet(isPresented: $showTickets) { NavigationStack { TicketListView() } }
            .sheet(isPresented: $showPoints) { PointsView() }
        }
    }

    // MARK: - 资料卡

    private var profileCard: some View {
        Button {
            route = SettingsRoute(focus: "myprofile")
        } label: {
            HStack(spacing: 14) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    Text(nickname)
                        .font(.aevis(18, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("点这里改名字和头像")
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nickname: String {
        let n = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "还没起名字" : n
    }

    /// 头像：纯渐变 + 首字。**不带玻璃** —— 这一页的玻璃已经全拆了。
    private var avatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [settings.accentColor.opacity(0.85),
                                 settings.accentColor.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            Text(String(nickname.prefix(1)))
                .font(.aevis(22, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - 打开 App 先进哪一页

    private var defaultTabCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("打开 App 先进哪一页")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                ForEach(MainTab.allCases) { tab in
                    let on = settings.defaultTab == tab.rawValue
                    Button {
                        settings.defaultTab = tab.rawValue
                    } label: {
                        Text(tab.title)
                            .font(.aevis(12.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(on ? settings.accentColor
                                             : Color.primary.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - 更多设置

    private var moreSettings: some View {
        card {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack(spacing: 12) {
                    icon("slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多设置")
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(showMore ? "点一下收起来" : "人设、音色、气泡、表情、音乐…")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: showMore ? "chevron.up" : "chevron.down")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                divider
                row("ta 的人设", "person.text.rectangle", "名字、性别、性格、说话方式") {
                    route = SettingsRoute(focus: "persona")
                }
                divider
                row("音色", "waveform", "用哪个声音念出来") {
                    route = SettingsRoute(focus: "voice")
                }
                divider
                row("主动消息", "bell.badge", "什么时候主动找你") {
                    route = SettingsRoute(focus: "proactive")
                }
                divider
                row("我的资料", "person.crop.square", "你自己的名字和头像") {
                    route = SettingsRoute(focus: "myprofile")
                }
                divider
                row("气泡样式", "bubble.left", "圆角、颜色、小尾巴") {
                    route = SettingsRoute(focus: "bubbles")
                }
                divider
                row("表情", "face.smiling", "发消息时带的表情") {
                    route = SettingsRoute(focus: "emoji")
                }
                divider
                row("聊天", "text.bubble", "默认进哪个页面") {
                    route = SettingsRoute(focus: "chat")
                }
                divider
                row("联网搜索", "magnifyingglass", "让 ta 自己上网查") {
                    route = SettingsRoute(focus: "search")
                }
                divider
                row("音乐", "music.note", "网易云登录、搜歌") {
                    route = SettingsRoute(focus: "music")
                }
                divider
                row("系统桥接", "link", "快捷指令、剪贴板") {
                    route = SettingsRoute(focus: "system")
                }
                divider
                row("MCP 外接工具", "puzzlepiece.extension", "接外面的工具给 ta 用") {
                    route = SettingsRoute(focus: "mcp")
                }
                divider
                row("控制台", "terminal", "ta 刚才做了什么") {
                    route = SettingsRoute(focus: "console")
                }
                divider
                row("分享与搬家", "square.and.arrow.up", "备份成文件、二维码") {
                    route = SettingsRoute(focus: "share")
                }
            }
        }
    }

    // MARK: - 每行右边那句话
    //
    // ⚠️ 这里每一个都是「读本地已有数据」，不联网、不解析 JSON。
    //    万一字段缺失也只是显示得丑一点，不会崩。

    private var inboxLine: String {
        if settings.accountEmail.isEmpty { return "登录后可查收通知和福利" }
        if inbox.unread > 0 { return "\(inbox.unread) 条未读 · 通知与福利积分" }
        return "通知与福利积分"
    }

    private var memoryLine: String {
        let count = MemoryStore.shared.items.count
        return count == 0 ? "还没有记忆" : "\(count) 条"
    }

    private var deviceLine: String { DeviceIdentity.pretty }

    private var modelLine: String {
        guard settings.isConfigured else { return "还没填 API Key，ta 不会说话" }
        let count = settings.apiProfiles.count
        if let p = settings.activeProfile {
            return count > 1 ? "在用「\(p.name)」，共 \(count) 套预设" : "在用「\(p.name)」"
        }
        return count > 1 ? "已填好，能用（存了 \(count) 套预设）" : "已填好，能用"
    }

    private var memberLine: String {
        guard let until = account.profile?.expiresAt else {
            return "还没开通（可在积分里兑换）"
        }
        if until < Date() { return "已到期（可在积分里续）" }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: until).day ?? 0
        let dayText = until.formatted(date: .abbreviated, time: .omitted)
        return "有效期到 " + dayText + (days > 0 ? "（还剩 \(days) 天）" : "")
    }

    private var accountLine: String {
        if !account.isConfigured { return "服务器连不上" }
        return account.statusLine
    }

    private var pointsLine: String {
        let pts = pointsService.points
        return pts > 0 ? "\(pts) 积分 · 可兑换会员" : "1 元 = 300 积分，充值后可换会员"
    }

    private var aiToolsLine: String {
        guard settings.aiToolsEnabled else { return "已关掉，只剩聊天" }
        let off = settings.disabledToolCategories.count
        return off == 0 ? "全部开着，聊天以外都能动手" : "关掉了 \(off) 类"
    }

    // MARK: - 零件（纯色，不带玻璃）

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.aevis(16, weight: .medium))
            .foregroundStyle(settings.accentColor)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(settings.accentColor.opacity(0.10))
            )
    }

    private func row(
        _ title: String,
        _ symbol: String,
        _ detail: String,
        badge: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            BlackBox.tap("我 · \(title)")
            action()
        } label: {
            HStack(spacing: 12) {
                icon(symbol)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.aevis(11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }

                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 62)
    }
}

/// 跳到设置里的某一张卡。`focus` 为空就是整页。
private struct SettingsRoute: Identifiable {
    let id = UUID()
    var focus: String?
}
