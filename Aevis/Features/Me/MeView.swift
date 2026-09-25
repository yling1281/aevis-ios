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
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    profileCard

                    card {
                        entry("记忆库", "brain.head.profile", memoryLine) {
                            route = SettingsRoute(focus: "memory")
                        }
                        entry("聊天记录", "bubble.left.and.bubble.right", chatLine) {
                            route = SettingsRoute(focus: "chat")
                        }
                        entry("模型接入", "bolt.horizontal", modelLine) {
                            route = SettingsRoute(focus: "model")
                        }
                    }

                    card {
                        entry("声音", "waveform", "音色、语速、朗读开关") {
                            route = SettingsRoute(focus: "voice")
                        }
                        entry("气泡与字体", "textformat.size", "我发的 / TA 发的分开调") {
                            route = SettingsRoute(focus: "bubbles")
                        }
                        entry("表情", "face.smiling", "内置表情名，也能导入自己的图") {
                            route = SettingsRoute(focus: "emoji")
                        }
                        entry("外观", "paintpalette", "玻璃、背景、主题色、字体") {
                            route = SettingsRoute(focus: "appearance")
                        }
                    }

                    card {
                        entry("陪伴", "heart", "录屏、一起听、通话") {
                            route = SettingsRoute(focus: "companion")
                        }
                        entry("主动找我说", "bell", "定时 / 不定时，还有 Bark 推送") {
                            route = SettingsRoute(focus: "proactive")
                        }
                        entry("朋友圈", "photo.on.rectangle.angled", "她发动态的节奏") {
                            route = SettingsRoute(focus: "moments")
                        }
                    }

                    card {
                        entry("快捷指令与系统", "command", "锁屏、屏幕使用时间都走它") {
                            route = SettingsRoute(focus: "system")
                        }
                        entry("外接能力（MCP）", "puzzlepiece.extension", "接外面的工具给她用") {
                            route = SettingsRoute(focus: "mcp")
                        }
                        entry("抖音", "play.rectangle", "解析链接、网页版点赞评论") {
                            route = SettingsRoute(focus: "douyin")
                        }
                        entry("音乐", "music.note", "网易云登录与搜索") {
                            route = SettingsRoute(focus: "music")
                        }
                        entry("百度网盘", "externaldrive.connected.to.line.below", baiduLine) {
                            route = SettingsRoute(focus: "baidupan")
                        }
                        entry("QQ 机器人", "bubble.left.and.bubble.right", qqBotLine) {
                            route = SettingsRoute(focus: "qqbot")
                        }
                        entry("QQ 桥接", "bubble.left.and.text.bubble.right", qqLine) {
                            route = SettingsRoute(focus: "qq")
                        }
                        entry("账号", "person.badge.key", accountLine) {
                            route = SettingsRoute(focus: "account")
                        }
                        entry("分享与搬家", "qrcode", "二维码传配置、备份成文件") {
                            route = SettingsRoute(focus: "share")
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
                        entry("全部设置", "gearshape", "所有卡片都在这一页") {
                            route = SettingsRoute(focus: nil)
                        }
                        entry("关于", "info.circle", "版本号") {
                            route = SettingsRoute(focus: "about")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("我")
            .navigationBarTitleDisplayMode(.inline)
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
        guard let url = URL(string: "https://lingyan.cyou/rules.html") else { return }
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

    private var chatLine: String {
        "当前这个人 \(ChatStore.shared.messages.count) 条"
    }

    private var modelLine: String {
        guard settings.isConfigured else { return "还没填 API Key，她不会说话" }
        let count = settings.apiProfiles.count
        if let profile = settings.activeProfile {
            return count > 1 ? "在用「\(profile.name)」，共 \(count) 套预设"
                             : "在用「\(profile.name)」"
        }
        return count > 1 ? "已填好，能用（存了 \(count) 套预设）" : "已填好，能用"
    }

    /// 百度网盘那一行。**必须能一眼看出卡在哪一步** ——
    /// 用户之前压根找不到这个入口，以为功能没做（其实一直在设置页里）。
    private var baiduLine: String {
        if !BaiduPanClient.shared.isConfigured {
            return "备份、搬家、让我读你的网盘（要填 AppKey）"
        }
        return BaiduPanClient.shared.isAuthorized ? "已授权，可以备份和搬家" : "凭据填好了，还差一步授权"
    }

    /// QQ 那一行同理：状态写在行上，别让人点进去才发现没配。
    private var qqLine: String {
        if !QQBridge.shared.isConfigured { return "看和发你的 QQ 消息（要填一个 OneBot 服务的地址）" }
        return settings.qqBridgeEnabled ? "已开启" : "地址填好了，但开关还关着"
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
        if !AccountService.shared.isConfigured { return "可选：以后接你自己的服务器（不填也能用）" }
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
        Button(action: action) {
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
}

/// 跳到设置里的某一张卡。`focus` 为空就是整页。
private struct SettingsRoute: Identifiable {
    let id = UUID()
    var focus: String?
}
