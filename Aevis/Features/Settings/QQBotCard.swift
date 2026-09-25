import SwiftUI

/// 「QQ 机器人（官方）」设置卡。
///
/// ⭐ 这条路和上面那张「QQ 桥接」是**两回事**：
/// - **QQ 桥接**连的是外面跑的 OneBot 服务（能读他自己账号的好友和群）——
///   但那需要一台一直开着的机器
/// - **这张卡**走官方机器人：平台替你登录，App 只是个 HTTPS + WebSocket 客户端 ——
///   **完全在手机上跑，不用电脑、不用服务器、不会过期**
///
/// 代价也说清楚：她在 QQ 上是**一个独立的号**，不是他本人的号；
/// 而且只能被动回复（别人先说话）。这些必须写在界面上，不能让人自己去猜。
struct QQBotCard: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var bot = QQBotService.shared

    @State private var showAppID = false
    @State private var appIDDraft = ""
    @State private var showSecret = false
    @State private var secretDraft = ""
    @State private var note: String?
    @State private var testing = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("QQ 机器人（官方）")

            enabledRow
            rule
            appIDRow
            rule
            secretRow
            rule
            sandboxRow
            rule
            keepAliveRow
            rule
            statusRow
            rule
            testRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let error = bot.lastError, !error.isEmpty {
                rule
                Text(error)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if !bot.log.isEmpty {
                rule
                recentList
            }

            rule
            howTo
        }
        .aevisGlass(cornerRadius: 20)
        .alert("AppID", isPresented: $showAppID) {
            TextField("机器人 AppID", text: $appIDDraft)
            Button("保存") {
                settings.qqBotAppID = appIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = "记下了。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("QQ 开放平台 → 你的机器人 → 开发设置里的 AppID。")
        }
        .alert("AppSecret", isPresented: $showSecret) {
            TextField("机器人 AppSecret", text: $secretDraft)
            Button("保存") {
                settings.qqBotSecret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = "存进钥匙串了。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("平台不支持二次查看 —— 页面上再点一次会强制重置，所以填进来之后自己留好一份。")
        }
    }

    // MARK: - 各行

    private var enabledRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("启用")
                    .font(.aevis(15))
                Text(settings.qqBotEnabled
                     ? (bot.state.isOnline ? "开着，而且在线" : "开着，正在连")
                     : "关着。整块 QQ 机器人都不生效")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBotEnabled)
                .labelsHidden()
                .tint(settings.accentColor)
                .onChange(of: settings.qqBotEnabled) { _, on in
                    Task {
                        if on { await QQBotService.shared.start() } else { QQBotService.shared.stop() }
                    }
                }
        }
    }

    private var appIDRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("AppID")
                    .font(.aevis(15))
                Text(settings.qqBotAppID.isEmpty ? "还没填" : settings.qqBotAppID)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.qqBotAppID.isEmpty ? "去填" : "修改") {
                appIDDraft = settings.qqBotAppID
                showAppID = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var secretRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("AppSecret")
                    .font(.aevis(15))
                Text(settings.qqBotSecret.isEmpty ? "还没填（只存在钥匙串里）" : "已填（存在钥匙串里）")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.qqBotSecret.isEmpty ? "去填" : "修改") {
                secretDraft = ""
                showSecret = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var sandboxRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("沙箱环境")
                    .font(.aevis(15))
                Text(settings.qqBotSandbox
                     ? "开着。只有你加进测试名单的号能用 —— 第一次接通建议先这样"
                     : "关着。正式环境，所有能加它的人都能用")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBotSandbox)
                .labelsHidden()
                .tint(settings.accentColor)
        }
    }

    private var keepAliveRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("后台保活")
                    .font(.aevis(15))
                Text(settings.qqBotKeepAlive
                     ? "开着。你在 QQ 里跟它说话时 App 在后台，靠这个才不掉线（代价：费电）"
                     : "关着。省电，但你切到 QQ 之后她就不回你了")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBotKeepAlive)
                .labelsHidden()
                .tint(settings.accentColor)
                .onChange(of: settings.qqBotKeepAlive) { _, on in
                    if on, settings.qqBotEnabled, bot.state.isOnline {
                        SilentKeeper.shared.start()
                    } else if !on {
                        SilentKeeper.shared.stop()
                    }
                }
        }
    }

    private var statusRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("状态")
                    .font(.aevis(15))
                Text(bot.state.label
                     + (bot.received > 0 ? "　收到 \(bot.received) 条 · 回了 \(bot.replied) 条" : ""))
                    .font(.aevis(11.5))
                    .foregroundStyle(bot.state.isOnline ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if bot.state.isOnline {
                Button("断开") { QQBotService.shared.stop() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            } else {
                Button("连上") { runConnect() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .disabled(busy || !QQBotClient.shared.isConfigured)
            }
        }
    }

    private var testRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("测试连接")
                    .font(.aevis(15))
                Text("换一次 token、问一次机器人是谁、取一次网关 —— 三步都过才算通")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(testing ? "测试中…" : "测试") { runTest() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(testing || !QQBotClient.shared.isConfigured)
        }
    }

    // MARK: - 最近的消息

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("最近在 QQ 上的来往")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("清空") { QQBotService.shared.clearLog() }
                    .font(.aevis(12))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            ForEach(bot.log.prefix(10)) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.mine ? "她" : line.from)
                        .font(.aevis(11.5, weight: .medium))
                        .foregroundStyle(line.mine ? settings.accentColor : Color.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(line.text)
                        .font(.aevis(12.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text(QQBotService.clock(line.at))
                        .font(.aevisMono(10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 说明

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这条路怎么走")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("1. 手机或电脑打开 q.qq.com，QQ 扫码登录（个人主体 + 实名）\n"
                 + "2. 创建一个机器人，拿到 AppID 和 AppSecret，填到上面\n"
                 + "3. 点「测试连接」，通了再点「连上」\n"
                 + "4. 在 QQ 里找到这个机器人，跟它说话 —— 她就会用你设的人设回你")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("说清楚两件事：她在 QQ 上是一个独立的号，不是你本人的 QQ；"
                 + "而且平台的规矩是只能被动回复 —— 你（或者群里 @ 它）先说话，它才能回。"
                 + "想要「她替我收发我自己的 QQ」，那得是外面跑 OneBot 那条路。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 动作

    private func runTest() {
        testing = true
        note = nil
        Task { @MainActor in
            defer { testing = false }
            note = await QQBotService.shared.test()
        }
    }

    private func runConnect() {
        busy = true
        note = "正在连…"
        Task { @MainActor in
            defer { busy = false }
            await QQBotService.shared.start()
            note = QQBotService.shared.state.isOnline
                ? "连上了。去 QQ 里找它说句话试试。"
                : "还没连上：" + QQBotService.shared.state.label
        }
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
