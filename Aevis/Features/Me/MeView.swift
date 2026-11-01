import SwiftUI

/// 我 —— 第四个 tab。
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
/// ## 2026-11-01 晚：换成 v2 那套长相
///
/// 上面那三条**一条都没放宽** —— v2 的 `V2Card` 本身就是纯色 + 0.5pt 细边、
/// 不带任何玻璃，正好是这一页能用的东西。改的只是观感：
/// 奶油底、22 圆角、圆形淡底图标、大标题栏（不再用系统导航栏）。
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
            VStack(spacing: 0) {
                V2TopBar(title: "我", subtitle: statusLine) {
                    Button {
                        route = SettingsRoute(focus: nil)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(V2.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(V2.soft(0.13)))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 14) {
                        profileCard

                        V2SectionTitle("账号")
                        V2Card {
                            V2Row(symbol: "crown",
                                  title: "会员",
                                  detail: memberLine,
                                  action: { showPoints = true })
                            V2Divider()
                            V2Row(symbol: "star.circle",
                                  title: "积分",
                                  detail: pointsLine,
                                  action: { showPoints = true })
                            V2Divider()
                            V2Row(symbol: "bell.badge",
                                  title: "站内信",
                                  detail: inboxLine,
                                  badge: inbox.unread,
                                  action: { showInbox = true })
                            V2Divider()
                            V2Row(symbol: "person.badge.key",
                                  title: "账号",
                                  detail: accountLine,
                                  action: { route = SettingsRoute(focus: "account") })
                            V2Divider()
                            V2Row(symbol: "iphone.gen3",
                                  title: "这台设备",
                                  detail: deviceLine,
                                  action: { route = SettingsRoute(focus: "device") })
                        }

                        V2SectionTitle("她")
                        V2Card {
                            V2Row(symbol: "bolt.horizontal",
                                  title: "模型接入",
                                  detail: modelLine,
                                  action: { route = SettingsRoute(focus: "model") })
                            V2Divider()
                            V2Row(symbol: "brain.head.profile",
                                  title: "记忆库",
                                  detail: memoryLine,
                                  action: { route = SettingsRoute(focus: "memory") })
                            V2Divider()
                            V2Row(symbol: "heart",
                                  title: "陪伴",
                                  detail: "录音、录屏陪伴",
                                  action: { route = SettingsRoute(focus: "companion") })
                            V2Divider()
                            V2Row(symbol: "lock.shield",
                                  title: "AI 权限",
                                  detail: aiToolsLine,
                                  action: { route = SettingsRoute(focus: "aitools") })
                            V2Divider()
                            V2Row(symbol: "heart.text.square",
                                  title: "健康",
                                  detail: "步数、跑步走路、心率、睡眠、经期",
                                  action: { showHealth = true })
                        }

                        V2SectionTitle("外观")
                        V2Card {
                            V2Row(symbol: "paintpalette",
                                  title: "外观",
                                  detail: "背景、主题色、字体",
                                  action: { route = SettingsRoute(focus: "appearance") })
                            V2Divider()
                            V2Row(symbol: "bubble.left",
                                  title: "气泡样式",
                                  detail: "圆角、颜色、小尾巴",
                                  action: { route = SettingsRoute(focus: "bubbles") })
                            V2Divider()
                            V2Row(symbol: "waveform",
                                  title: "音色",
                                  detail: "用哪个声音念出来",
                                  action: { route = SettingsRoute(focus: "voice") })
                        }

                        defaultTabCard

                        V2SectionTitle("帮助")
                        V2Card {
                            V2Row(symbol: "questionmark.circle",
                                  title: "怎么使用 / 规则 / 常见问题",
                                  detail: "怎么开始用、有哪些规则、常见问题",
                                  action: { showRules = true })
                            V2Divider()
                            V2Row(symbol: "envelope",
                                  title: "帮助与反馈",
                                  detail: "提问题、看客服回复",
                                  action: { showTickets = true })
                            V2Divider()
                            V2Row(symbol: "doc.text",
                                  title: "免责声明",
                                  detail: "风险、数据存放、第三方服务",
                                  action: { showDisclaimer = true })
                            V2Divider()
                            V2Row(symbol: "info.circle",
                                  title: "关于",
                                  detail: "版本号",
                                  action: { route = SettingsRoute(focus: "about") })
                        }

                        moreSettings

                        // 退出登录单独摆一张卡，离开最远 —— 免得手滑。
                        V2Card {
                            V2Row(symbol: "rectangle.portrait.and.arrow.right",
                                  title: "退出登录",
                                  detail: account.isSignedIn ? "退出后要重新登录才能用" : "还没登录",
                                  tint: V2.alert,
                                  showsChevron: false,
                                  action: {
                                      BlackBox.tap("我 · 退出登录")
                                      account.signOut()
                                  })
                        }
                        .opacity(account.isSignedIn ? 1 : 0.5)
                        .disabled(!account.isSignedIn)

                        Text("Aevis · 个人开发者在做的小东西")
                            .font(.aevis(V2.micro))
                            .foregroundStyle(V2.dim(0.28))
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, V2.gutter)
                    .padding(.bottom, 26)
                }
            }
            .v2Page()
            .toolbar(.hidden, for: .navigationBar)
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

                VStack(alignment: .leading, spacing: 5) {
                    Text(nickname)
                        .font(.aevis(18, weight: .semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        V2Pill(memberPillText)
                        Text("点这里改名字和头像")
                            .font(.aevis(V2.tiny))
                            .foregroundStyle(V2.dim(0.42))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(V2.dim(0.22))
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                    .fill(V2.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                    .strokeBorder(V2.stroke, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var nickname: String {
        let n = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "还没起名字" : n
    }

    /// 头像：圆形柔底 + 首字。**不带玻璃** —— 这一页的玻璃已经全拆了。
    private var avatar: some View {
        ZStack {
            Circle().fill(V2.soft(0.16))
            Text(String(nickname.prefix(1)))
                .font(.aevis(21, weight: .semibold))
                .foregroundStyle(V2.accent)
        }
        .frame(width: 56, height: 56)
    }

    // MARK: - 打开 App 先进哪一页

    private var defaultTabCard: some View {
        V2Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("打开 App 先进哪一页")
                    .font(.aevis(V2.sub, weight: .medium))
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
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(on ? V2.accent : V2.well)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 14)
        }
    }

    // MARK: - 更多设置

    private var moreSettings: some View {
        V2Card {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack(spacing: 13) {
                    V2IconBox("slider.horizontal.3")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多设置")
                            .font(.aevis(V2.body, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(showMore ? "点一下收起来" : "人设、表情、音乐、外接工具…")
                            .font(.aevis(V2.tiny))
                            .foregroundStyle(V2.dim(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: showMore ? "chevron.up" : "chevron.down")
                        .font(.aevis(12, weight: .semibold))
                        .foregroundStyle(V2.dim(0.22))
                }
                .padding(.horizontal, V2.gutter)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showMore {
                V2Divider()
                V2Row(symbol: "person.text.rectangle",
                      title: "ta 的人设",
                      detail: "名字、性别、性格、说话方式",
                      action: { route = SettingsRoute(focus: "persona") })
                V2Divider()
                V2Row(symbol: "bell.badge",
                      title: "主动消息",
                      detail: "什么时候主动找你",
                      action: { route = SettingsRoute(focus: "proactive") })
                V2Divider()
                V2Row(symbol: "person.crop.square",
                      title: "我的资料",
                      detail: "你自己的名字和头像",
                      action: { route = SettingsRoute(focus: "myprofile") })
                V2Divider()
                V2Row(symbol: "face.smiling",
                      title: "表情",
                      detail: "发消息时带的表情",
                      action: { route = SettingsRoute(focus: "emoji") })
                V2Divider()
                V2Row(symbol: "text.bubble",
                      title: "聊天",
                      detail: "默认进哪个页面",
                      action: { route = SettingsRoute(focus: "chat") })
                V2Divider()
                V2Row(symbol: "magnifyingglass",
                      title: "联网搜索",
                      detail: "让 ta 自己上网查",
                      action: { route = SettingsRoute(focus: "search") })
                V2Divider()
                V2Row(symbol: "music.note",
                      title: "音乐",
                      detail: "网易云登录、搜歌",
                      action: { route = SettingsRoute(focus: "music") })
                V2Divider()
                V2Row(symbol: "link",
                      title: "系统桥接",
                      detail: "快捷指令、剪贴板",
                      action: { route = SettingsRoute(focus: "system") })
                V2Divider()
                V2Row(symbol: "puzzlepiece.extension",
                      title: "MCP 外接工具",
                      detail: "接外面的工具给 ta 用",
                      action: { route = SettingsRoute(focus: "mcp") })
                V2Divider()
                V2Row(symbol: "terminal",
                      title: "控制台",
                      detail: "ta 刚才做了什么",
                      action: { route = SettingsRoute(focus: "console") })
                V2Divider()
                V2Row(symbol: "square.and.arrow.up",
                      title: "分享与搬家",
                      detail: "备份成文件、二维码",
                      action: { route = SettingsRoute(focus: "share") })
            }
        }
    }

    // MARK: - 顶部/卡片上那几句
    //
    // ⚠️ 这里每一个都是「读本地已有数据」，不联网、不解析 JSON。
    //    万一字段缺失也只是显示得丑一点，不会崩。

    private var statusLine: String {
        if !account.isSignedIn { return "还没登录" }
        let pts = pointsService.points
        return pts > 0 ? "\(pts) 积分" : "已登录"
    }

    private var memberPillText: String {
        guard let until = account.profile?.expiresAt else { return "未开通" }
        return until < Date() ? "已到期" : "会员"
    }

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
}

/// 跳到设置里的某一张卡。`focus` 为空就是整页。
private struct SettingsRoute: Identifiable {
    let id = UUID()
    var focus: String?
}
