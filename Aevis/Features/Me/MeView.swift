import SwiftUI

/// 我 —— 微信的第四个 tab。
///
/// 上面是我的资料，下面是各类设置的**直达入口**：
/// 点哪一条就跳到那一张卡，不用再在一条很长的设置页里翻。
struct MeView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var route: SettingsRoute?
    @State private var showDisclaimer = false
    /// 「更多设置」折起来了没有。默认收起 —— 这一页的主角是上面那些常点的。
    @State private var showMore = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileCard

                    // 这里只留**平时真的会点的**那些。其余 11 项没删，
                    // 全都在「全部设置」里按组分好了 ——
                    // 以前这一页和设置页是一一对应的两份，用户同一件事要找两遍。
                    card {
                        entry("模型接入", "bolt.horizontal", modelLine) {
                            route = SettingsRoute(focus: "model")
                        }
                        entry("记忆库", "brain.head.profile", memoryLine) {
                            route = SettingsRoute(focus: "memory")
                        }
                        entry("这台设备", "iphone.gen3", deviceLine) {
                            route = SettingsRoute(focus: "device")
                        }
                        entry("账号", "person.badge.key", accountLine) {
                            route = SettingsRoute(focus: "account")
                        }
                    }

                    card {
                        entry("陪伴", "heart", "录屏、一起听、通话") {
                            route = SettingsRoute(focus: "companion")
                        }
                        entry("外观", "paintpalette", "玻璃、背景、主题色、字体") {
                            route = SettingsRoute(focus: "appearance")
                        }
                        entry("朋友圈", "photo.on.rectangle.angled", "\(Pronoun.current)发动态的节奏、配图、样式") {
                            route = SettingsRoute(focus: "moments")
                        }
                        entry("百度网盘", "externaldrive.connected.to.line.below", baiduLine) {
                            route = SettingsRoute(focus: "baidupan")
                        }
                        entry("QQ 机器人", "bubble.left.and.bubble.right", qqBotLine) {
                            route = SettingsRoute(focus: "qqbot")
                        }
                    }

                    defaultTabCard

                    card {
                        // 规则和免责声明放在**最上面两条**：它们是要给人看的，
                        // 不该埋在设置里（这次的教训：功能藏进设置页 = 用户以为没做）。
                        entry("使用规则 / 常见问题", "questionmark.circle",
                              "怎么领注册码、群规则、常见问题") {
                            openRules()
                        }
                        entry("免责声明", "doc.text",
                              "风险、数据存放、第三方服务") {
                            showDisclaimer = true
                        }
                        entry("关于", "info.circle", "版本号") {
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
            // ⚠️ 右上角那个齿轮**已经去掉了**（用户 2026-09-26 原话：
            // 「我右上角那个设置没必要啊，你就不是有这些设置」）。
            // 但十几项设置的入口不能跟着消失 —— 它们现在**折在这一页最下面**
            // （`moreSettings`），不占地方又随时点得到。
            // **别再往这里加"全部设置"按钮** —— 他嫌多余，这已经是第二次提了。
            .sheet(item: $route) { item in
                SettingsView(focus: item.focus)
                    .environmentObject(personaStore)
                    .environmentObject(settings)
                    .environmentObject(ChatStore.shared)
            }
            .fullScreenCover(isPresented: $showDisclaimer) {
                DisclaimerView()
            }
        }
    }

    /// 规则页在网站上单独一页 —— 群里发的、App 里点的，都是同一个地址。
    private func openRules() {
        guard let url = AevisHosts.siteURL("/rules.html") else { return }
        openURL(url)
    }

    // MARK: - 我的资料

    private var profileCard: some View {
        Button {
            route = SettingsRoute(focus: "myprofile")
        } label: {
            HStack(spacing: 14) {
                AevisAvatar(source: .me, size: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.nickname.isEmpty ? "还没起名字" : profile.nickname)
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
            .aevisGlass(cornerRadius: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 打开 App 先进哪一页
    //
    // 出厂是「通讯录」（用户要求「进去就是联系人」），
    // 但**这是个选项**，不是我们替他定死的。

    private var defaultTabCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("打开 App 先进哪一页")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.primary)

            Picker("", selection: $settings.defaultTab) {
                ForEach(MainTab.allCases) { tab in
                    Text(tab.title).tag(tab.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 每行右边那句话

    private var memoryLine: String {
        let count = MemoryStore.shared.items.count
        return count == 0 ? "还没有记忆" : "\(count) 条"
    }

    /// 设备码那一行 **直接把码写在行上** —— 用户要的就是这串东西拿去网页上填，
    /// 让他点进去才能看到属于白走一步。
    private var deviceLine: String {
        DeviceIdentity.pretty
    }

    private var modelLine: String {
        guard settings.isConfigured else { return "还没填 API Key，\(Pronoun.current)不会说话" }
        let count = settings.apiProfiles.count
        if let profile = settings.activeProfile {
            return count > 1 ? "在用「\(profile.name)」，共 \(count) 套预设"
                             : "在用「\(profile.name)」"
        }
        return count > 1 ? "已填好，能用（存了 \(count) 套预设）" : "已填好，能用"
    }

    /// 百度网盘那一行。**必须能一眼看出卡在哪一步** ——
    /// 用户之前压根找不到这个入口，以为功能没做（其实一直在设置页里）。
    /// 现在凭据内嵌在服务器上，所以只剩两种状态：连上了 / 还没连。
    private var baiduLine: String {
        if BaiduPanClient.shared.isAuthorized { return "已连接，可以备份和搬家" }
        return "备份、搬家、让我读你的网盘（点一下就连上）"
    }

    /// QQ 官方机器人那一行 —— **这条路才是在手机上跑、不用电脑的**。
    private var qqBotLine: String {
        if !QQBotClient.shared.isConfigured { return "在手机上跑，不用电脑（要填 AppID 和 AppSecret）" }
        guard settings.qqBotEnabled else { return "填好了，但开关还关着" }
        return QQBotService.shared.state.isOnline ? "在线" : QQBotService.shared.state.label
    }

    /// 账号那一行。**不填也能用**这件事必须写在行上，
    /// 否则会让人以为"没登录就不能用"。
    private var accountLine: String {
        if !AccountService.shared.isConfigured { return "服务器连不上" }
        return AccountService.shared.statusLine
    }

    // MARK: - 零件

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func entry(
        _ title: String,
        _ symbol: String,
        _ detail: String,
        action: @escaping () -> Void
    ) -> some View {
        // ⚠️ 「我」页**所有**入口都走这一个函数 —— 在这里记一笔，
        // 这一页点了什么一个都不会漏（用户要求「不管点了哪个按键都要记起来」）。
        // 放在这里而不是每个调用点：调用点十几处，漏一个就永远查不到。
        Button {
            BlackBox.tap("我 · \(title)")
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(AppSettings.shared.accentColor)
                    .frame(width: 34, height: 34)
                    .aevisGlass(cornerRadius: 12)

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

                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 其余那些不常点、但**绝对不能没有入口**的设置。
    ///
    /// ## 为什么要折起来
    /// 用户 2026-09-26 说「我」右上角那个齿轮没必要。可那个齿轮一点进去
    /// **是整个设置页** —— 直接删掉，下面这十几项就真没入口了，
    /// 而"功能不见了"是他最烦的一类问题（已经栽过两次）。
    /// 所以折在这一页最下面：平时不占地方，真要找的一定找得到。
    ///
    /// ⚠️ **别再改回"右上角放个齿轮"** —— 他嫌那个多余，而且提过一次了。
    private var moreSettings: some View {
        card {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showMore.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.aevis(16, weight: .medium))
                        .foregroundStyle(AppSettings.shared.accentColor)
                        .frame(width: 34, height: 34)
                        .aevisGlass(cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("更多设置")
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(showMore ? "点一下收起来" : "人设、音色、气泡、表情、音乐、抖音…")
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
                entry("TA 的人设", "person.text.rectangle", "名字、性别、性格、说话方式") {
                    route = SettingsRoute(focus: "persona")
                }
                divider
                entry("音色", "waveform", "用哪个声音念出来") {
                    route = SettingsRoute(focus: "voice")
                }
                divider
                entry("主动消息", "bell.badge", "她什么时候主动找你") {
                    route = SettingsRoute(focus: "proactive")
                }
                divider
                entry("我的资料", "person.crop.square", "你自己的名字和头像") {
                    route = SettingsRoute(focus: "myprofile")
                }
                divider
                entry("气泡样式", "bubble.left", "圆角、颜色、小尾巴") {
                    route = SettingsRoute(focus: "bubbles")
                }
                divider
                entry("表情", "face.smiling", "她发消息时带的表情") {
                    route = SettingsRoute(focus: "emoji")
                }
                divider
                entry("聊天", "text.bubble", "默认进哪个页面") {
                    route = SettingsRoute(focus: "chat")
                }
                divider
                entry("联网搜索", "magnifyingglass", "让她自己上网查") {
                    route = SettingsRoute(focus: "search")
                }
                divider
                entry("音乐", "music.note", "网易云登录、搜歌") {
                    route = SettingsRoute(focus: "music")
                }
                divider
                entry("抖音", "play.rectangle", "刷视频、点赞") {
                    route = SettingsRoute(focus: "douyin")
                }
                divider
                entry("QQ 桥接", "message", "接上你自己的 QQ") {
                    route = SettingsRoute(focus: "qq")
                }
                divider
                entry("系统桥接", "link", "快捷指令、剪贴板") {
                    route = SettingsRoute(focus: "system")
                }
                divider
                entry("MCP 外接工具", "puzzlepiece.extension", "接外面的工具给她用") {
                    route = SettingsRoute(focus: "mcp")
                }
                divider
                entry("控制台", "terminal", "她刚才做了什么") {
                    route = SettingsRoute(focus: "console")
                }
                divider
                entry("分享与搬家", "square.and.arrow.up", "备份成文件、二维码") {
                    route = SettingsRoute(focus: "share")
                }
            }
        }
    }

    /// 列表项之间的细线（`entry` 自己不带）。
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
