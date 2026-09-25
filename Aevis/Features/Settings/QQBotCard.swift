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
    @State private var showCodeKey = false
    @State private var codeKeyDraft = ""
    @State private var showCodeKeyword = false
    @State private var codeKeywordDraft = ""
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
            rule
            codeEnabledRow

            // 打开之后才展开细节 —— 关着的时候这一整块是噪音
            if settings.qqBotCodeEnabled {
                rule
                codeKeywordRow
                rule
                codeKeyRow
                if !bot.knownGroups.isEmpty {
                    rule
                    codeGroups
                }
                rule
                codeHowTo
            }

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
        .alert("发码钥匙", isPresented: $showCodeKey) {
            TextField("从管理后台复制过来", text: $codeKeyDraft)
            Button("保存") {
                settings.qqBotCodeKey = codeKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = settings.qqBotCodeKey.isEmpty
                    ? "清空了。这样机器人发不出注册码。"
                    : "存进钥匙串了。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("打开 account.lingyan.cyou/admin，登录后「QQ 机器人发注册码」那一块里有个「复制」。"
                 + "它就像这个功能的总闸 —— 别发到群里或贴到别处。")
        }
        .alert("触发词", isPresented: $showCodeKeyword) {
            TextField("注册", text: $codeKeywordDraft)
            Button("保存") {
                let trimmed = codeKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.qqBotCodeKeyword = trimmed.isEmpty ? "注册" : trimmed
                note = "以后就认「\(settings.qqBotCodeKeyword)」这个词。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("群里 @机器人 发这个词 → 拿口令；私聊发「这个词 + 空格 + 口令」→ 拿注册码。")
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

    // MARK: - 发注册码

    /// 触发词（空的话回落到「注册」）。
    /// 取法在 QQCodeGate 里也有同一份 —— 两处必须是同一个回落值，
    /// 不然界面上写「注册」、实际认别的词。
    private var keywordText: String {
        let raw = settings.qqBotCodeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "注册" : raw
    }

    private var codeEnabledRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("发注册码")
                    .font(.aevis(15))
                Text(codeStateText)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.qqBotCodeEnabled)
                .labelsHidden()
                .tint(settings.accentColor)
        }
    }

    /// 那一行小字要说清「现在卡在哪一步」—— 只说"开着/关着"等于没说。
    private var codeStateText: String {
        if !settings.qqBotCodeEnabled { return "关着。谁发关键词都只是普通聊天" }
        if settings.qqBotCodeKey.isEmpty, BuiltInSecrets.accountBotKey.isEmpty {
            return "开着，但缺「发码钥匙」，现在发不出去"
        }
        if !settings.qqBotEnabled { return "开着，但上面的 QQ 机器人本身没启用" }
        if !bot.state.isOnline { return "开着，等 QQ 机器人连上就能发" }
        return "开着。群里 @我 发「\(keywordText)」领口令，再私聊换码"
    }

    private var codeKeyRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("发码钥匙")
                    .font(.aevis(15))
                Text(codeKeyState)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.qqBotCodeKey.isEmpty ? "去填" : "改") {
                codeKeyDraft = ""
                showCodeKey = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var codeKeyState: String {
        if !settings.qqBotCodeKey.isEmpty { return "已填（存在钥匙串里）" }
        if !BuiltInSecrets.accountBotKey.isEmpty { return "用的是包里内置的，不用你填" }
        return "还没填 —— 去 account.lingyan.cyou/admin 复制一个"
    }

    private var codeKeywordRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("触发词")
                    .font(.aevis(15))
                Text("群里发「\(keywordText)」，私聊发「\(keywordText) 口令」")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("改") {
                codeKeywordDraft = keywordText
                showCodeKeyword = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    /// 哪些群能领。**一个都不勾 = 不限**。
    private var codeGroups: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("哪些群能领")
                .font(.aevis(15))
            Text(settings.qqBotCodeGroups.isEmpty
                 ? "现在是不限 —— 机器人被 @ 到的任何一个群都能领。"
                 : "只在勾选的 \(settings.qqBotCodeGroups.count) 个群里发，别的群一句都不回。")
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(bot.knownGroups, id: \.self) { id in
                HStack(spacing: 8) {
                    Text(Self.shortGroup(id))
                        .font(.aevisMono(11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Toggle("", isOn: groupBinding(id))
                        .labelsHidden()
                        .tint(settings.accentColor)
                }
            }

            Text("这些是机器人被 @ 过的群。平台只给一串编号，看不到群名 —— "
                 + "对着时间来认就行（刚 @ 过哪个群，哪个就会出现在这儿）。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.qqBotCodeGroups.contains(id) },
            set: { on in
                var list = settings.qqBotCodeGroups
                if on {
                    if !list.contains(id) { list.append(id) }
                } else {
                    list.removeAll { $0 == id }
                }
                settings.qqBotCodeGroups = list
            }
        )
    }

    /// 群编号是 32 位十六进制，整串铺出来会撑破一行 —— 掐头去尾留中间的点。
    private static func shortGroup(_ id: String) -> String {
        guard id.count > 14 else { return id }
        return String(id.prefix(6)) + "…" + String(id.suffix(5))
    }

    private var codeHowTo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("注册码怎么领")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("1. 他在群里 @这个机器人，发一句「\(keywordText)」\n"
                 + "2. 机器人回一个口令（几分钟内有效、只能用一次）\n"
                 + "3. 他私聊机器人，发「\(keywordText) 口令」\n"
                 + "4. 机器人把注册码私聊发给他")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("一个 QQ 只能领一张；已经领过的再来，机器人会把原来那张再发一遍。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("为什么不能「私聊直接给码」：官方没有可用的查群成员接口"
                 + "（群成员列表还在内邀，只给白名单机器人），而且私聊和群里用的是"
                 + "两套不同的编号，对不上。所以只能用「他在群里 @ 得到机器人」"
                 + "这件事来证明他是群成员 —— 口令就是把这两个身份串起来的那根线。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
