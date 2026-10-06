import SwiftUI

/// 「微信机器人（本地 Linux）」设置卡。
///
/// ⭐ 这条路和上面的「QQ 机器人（官方）」**不是一回事**：
/// - QQ 那条是 Swift 里直接开 WebSocket，跑在 App 进程里；
/// - 微信这条（腾讯官方 ClawBot / iLink 通道）**整个跑在 App 内置的真 Linux 里**
///   —— 扫码绑定、35 秒长轮询全在 iSH 的 Alpine 里，**不经过我们的账号服务器，
///   也不经过任何一台电脑**（老板 2026-10-06 的原话就是这个意思）。
///
/// 代价也写在界面上，不让人自己猜：
/// · iOS 会把后台 App 挂起，**连带把 Linux 里的后台进程一起停** —— 只能靠
///   「后台保活」（静音音频）尽量拖住；真被挂了，切回前台自动重新拉起来。
/// · 没有 history 接口 ⇒ 只能看「绑定之后、用户↔bot」这一条会话。
struct WeChatBotCard: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var bot = WeChatBotService.shared

    @State private var busyProbe = false
    @State private var busyBind = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("微信机器人（本地 Linux）")

            enabledRow
            rule
            keepAliveRow
            rule
            probeRow
            if !bot.probes.isEmpty {
                rule
                probeList
            }
            rule
            bindRow
            if let payload = bot.qrPayload {
                rule
                qrBlock(payload)
            }
            rule
            statusRow
            rule
            unbindRow

            if let note {
                rule
                noteBlock(note)
            }

            if let error = bot.lastError, !error.isEmpty {
                rule
                noteBlock(error, warn: true)
            }

            if !bot.incoming.isEmpty {
                rule
                recentList
            }

            rule
            howTo
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 各行

    private var enabledRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("启用")
                    .font(.aevis(15))
                Text(settings.weChatBotEnabled
                     ? "开着。这块的扫码绑定和收消息都在内置 Linux 里跑"
                     : "关着。整块微信机器人都不生效")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.weChatBotEnabled)
                .labelsHidden()
                .tint(settings.accentColor)
                .onChange(of: settings.weChatBotEnabled) { _, on in
                    Task {
                        if on {
                            if !settings.weChatBotToken.isEmpty {
                                await WeChatBotService.shared.startPolling()
                            }
                        } else {
                            await WeChatBotService.shared.stopPolling()
                            SilentKeeper.shared.stop()
                        }
                    }
                }
        }
    }

    private var keepAliveRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("后台保活")
                    .font(.aevis(15))
                Text(settings.weChatBotKeepAlive
                     ? "开着。你在微信里跟它说话时 App 在后台，靠这个才尽量不掉线"
                        + "（代价：费电）"
                     : "关着。省电，但 App 一进后台被挂起，它就不收消息了")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $settings.weChatBotKeepAlive)
                .labelsHidden()
                .tint(settings.accentColor)
                .onChange(of: settings.weChatBotKeepAlive) { _, on in
                    if on, settings.weChatBotEnabled, !settings.weChatBotToken.isEmpty {
                        SilentKeeper.shared.start()
                    } else if !on {
                        SilentKeeper.shared.stop()
                    }
                }
        }
    }

    private var probeRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("先跑自检")
                    .font(.aevis(15))
                Text("三件事各测一遍：内置 Linux 里出不出网、后台作业能不能常驻、"
                     + "退到后台会不会被 iOS 挂起。跑完点「看结果」看真实数据。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Button(busyProbe ? "自检中…" : "先跑自检") { runProbe() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .disabled(busyProbe)
                Button("看结果") { runRecheck() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bindRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("微信扫码绑定")
                    .font(.aevis(15))
                Text(bindHint)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(busyBind ? "处理中…" : (bot.state.isBound ? "重新绑定" : "去绑定")) { runBind() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(busyBind || !settings.weChatBotEnabled)
        }
    }

    private var bindHint: String {
        if !settings.weChatBotEnabled { return "先把上面的「启用」打开" }
        if bot.state.isBound { return bot.boundSummary }
        return "点一下就出码（在内置 Linux 里取的），用微信扫，扫上就自动存起来"
    }

    private var statusRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("状态")
                    .font(.aevis(15))
                Text(bot.state.label + (bot.received > 0 ? "　收到 \(bot.received) 条" : ""))
                    .font(.aevis(11.5))
                    .foregroundStyle(bot.state.isBound ? Color.green : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if bot.state == .polling {
                Button("停轮询") { Task { await WeChatBotService.shared.stopPolling() } }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            } else if !settings.weChatBotToken.isEmpty {
                Button("起轮询") { Task { await WeChatBotService.shared.startPolling() } }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var unbindRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("解绑")
                    .font(.aevis(15))
                Text("只删掉手机里存的 token。要彻底断开，还得去微信那边把它解绑。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("解绑") { runUnbind() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(settings.weChatBotToken.isEmpty)
        }
    }

    // MARK: - 二维码

    private func qrBlock(_ payload: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("用微信扫这个码")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .center, spacing: 0) {
                if let qr = ConfigShare.image(for: payload) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                } else {
                    Text("码画不出来（这台设备上没有二维码生成器）")
                        .font(.aevis(12))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("扫上之后这里会自动变成「已绑定」，不用手动刷新。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 自检结果

    private var probeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(bot.probes) { probe in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(probe.ok ? "通过" : "没过")
                            .font(.aevis(11, weight: .semibold))
                            .foregroundStyle(probe.ok ? Color.green : Color.orange)
                        Text(probe.title)
                            .font(.aevis(12, weight: .medium))
                    }
                    Text(probe.command)
                        .font(.aevisMono(10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(probe.output.isEmpty ? "（没有输出）" : probe.output)
                        .font(.aevisMono(10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 最近收到的

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("最近收到的")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("清空") { WeChatBotService.shared.clearIncoming() }
                    .font(.aevis(12))
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            ForEach(bot.incoming.prefix(10)) { line in
                HStack(alignment: .top, spacing: 8) {
                    Text(line.from)
                        .font(.aevis(11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Text(line.text)
                        .font(.aevis(12.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
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

            Text("为什么走本地的 Linux：这条链路要一个 35 秒一次、常驻不断的长轮询，"
                 + "而且增量游标只存在轮询的人身上。把它放进 App 里那个真 Linux 的后台进程，"
                 + "既不用电脑、也不用服务器。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("iOS 上做不到的那一步：App 一旦被系统挂起，Linux 里的后台进程也一起停。"
                 + "「后台保活」能尽量拖住，但拖不住的时候就得切回前台，"
                 + "\(Pronoun.current)会自动把轮询器重新拉起来。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("顺序：1. 打开「启用」　2. 点「先跑自检」，三项都过了再往下　"
                 + "3. 点「去绑定」，用微信扫码　4. 绑上之后就能在设置里看到收到的消息")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 动作

    private func runProbe() {
        busyProbe = true
        note = nil
        Task { @MainActor in
            defer { busyProbe = false }
            await WeChatBotService.shared.probe()
            note = "自检跑完了。第 2、3 项要过一会儿点「看结果」才算数。"
        }
    }

    private func runRecheck() {
        Task { @MainActor in
            await WeChatBotService.shared.recheckBackground()
        }
    }

    private func runBind() {
        busyBind = true
        note = nil
        Task { @MainActor in
            defer { busyBind = false }
            await WeChatBotService.shared.startBind()
            note = WeChatBotService.shared.state.isBound
                ? "绑上了。\(WeChatBotService.shared.boundSummary)"
                : "还没绑上：" + WeChatBotService.shared.state.label
        }
    }

    private func runUnbind() {
        Task { @MainActor in
            await WeChatBotService.shared.unbind()
            note = "本地 token 删掉了。想彻底断开，还得去微信那边把它解绑。"
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

    private func noteBlock(_ text: String, warn: Bool = false) -> some View {
        Text(text)
            .font(.aevis(11.5))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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
