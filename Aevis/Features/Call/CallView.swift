import SwiftUI

/// 实时通话界面。
///
/// 全屏 + 深色，就是通话该有的样子：她在那儿，你说话，她回话。
/// 屏幕下方实时显示**她听到的内容**，这样没听清的时候你能看见她听到了什么。
struct CallView: View {
    @ObservedObject private var call = CallService.shared
    @ObservedObject private var listen = ListenService.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    /// 通话里**打**的那句话。
    ///
    /// 用户 2026-10-01：「第三个的话呢，可以加点功能」。
    /// 麦克风在吵的地方根本不好使（地铁、风大、旁边有人），
    /// 而「电话里说不出话」会让她显得很笨 —— 留一个能打字的入口。
    @State private var draft = ""
    @FocusState private var typing: Bool

    private var persona: Persona { personaStore.persona }

    var body: some View {
        ZStack {
            AevisBackground()

            VStack(spacing: 0) {
                topBar

                Spacer(minLength: 10)

                portrait

                Spacer(minLength: 10)

                statusBlock

                if call.state == .active { inputBar }

                controls
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .task {
            #if DEBUG
            // 截图自检专用（`-aevisOpenCall`）。
            // ⚠️ 模拟器里没有麦克风权限、也没有 API Key，真起一通电话必然失败，
            //    失败之后 `state` 回到 `.idle` —— 免提按钮和打字框**根本不显示**，
            //    截出来的还是老样子。所以这条路上只造状态，不碰任何音频设备。
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenCall") {
                call.previewStart()
                return
            }
            #endif
            await call.start(
                persona: persona,
                config: settings.llm,
                memory: settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
            )
        }
        .onDisappear {
            call.hangUp()
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        VStack(spacing: 6) {
            Text(persona.name.isEmpty ? "TA" : persona.name)
                .font(.aevis(22, weight: .semibold))
                .foregroundStyle(.primary)

            // ⚠️ 只在**通话中**才开这个每秒的计时器。
            //
            // 用户 2026-10-01：「你 UI 做的流畅一点」。
            // 原来这里是不加条件的 `TimelineView(.periodic(by: 1))` ——
            // 于是**接通前那几秒**（正在起麦克风、正在要权限）也在每秒唤醒一次
            // 主线程刷这一整块，跟正在做的重活儿抢那一帧。`.connecting` 那几秒
            // 恰恰是「卡不卡」最容易被看出来的地方。
            //
            // ⚠️ 别把这个 `if` 挪到 `TimelineView` 里面 —— 那样视图树深度不变，
            //    该醒还是每秒醒。要在**外层**决定建不建它。
            if call.state == .active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(CallService.clock(call.elapsed))
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        // 数字宽度固定，跳秒时不会把左右挤得抖一下
                        .contentTransition(.numericText(countsDown: false))
                }
            } else {
                Text(clockText)
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var clockText: String {
        switch call.state {
        case .idle: return ""
        case .connecting: return "正在接通…"
        case .active: return CallService.clock(call.elapsed)
        }
    }

    // MARK: - 中间：她 + 波形

    private var portrait: some View {
        VStack(spacing: 18) {
            AevisAvatar(source: .ai, size: 128, seed: persona.avatarSeed)
                .overlay(
                    Circle()
                        .strokeBorder(
                            settings.accentColor.opacity(call.thinking ? 0.65 : 0.25),
                            lineWidth: call.thinking ? 3 : 1.5
                        )
                        .frame(width: 142, height: 142)
                )
                .shadow(color: settings.accentColor.opacity(0.35), radius: call.thinking ? 22 : 8)

            waveform
        }
    }

    /// 音量波形。没在说话时就是平的 —— 一眼看出麦克风在不在工作。
    private var waveform: some View {
        HStack(spacing: 4) {
            ForEach(0..<17, id: \.self) { index in
                Capsule()
                    .fill(settings.accentColor.opacity(0.85))
                    .frame(
                        width: 3.5,
                        height: barHeight(index)
                    )
            }
        }
        .frame(height: 34)
        .animation(.easeOut(duration: 0.12), value: listen.level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        // 中间高两边低，再叠上实时音量
        let center = 8.0
        let distance = abs(Double(index) - center) / center
        let shape = 1.0 - distance * 0.75
        let base = 3.0
        let live = max(0.06, listen.level)
        return CGFloat(base + live * 30 * shape)
    }

    // MARK: - 状态区

    private var statusBlock: some View {
        VStack(spacing: 8) {
            if let error = call.errorText {
                Text(error)
                    .font(.aevis(13))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 苹果那套来电界面没弹出来时，把她为什么没弹**说出来**。
            //
            // 用户 2026-10-01 报「电话弹窗不知道为什么弹不了」—— 以前这里失败
            // 只在黑匣子里留一行，他点了打电话看到的就是"什么都没发生"。
            // 现在摆在这儿：一眼知道是签名没资格还是系统版本不够，
            // 而且下面那句要让他放心（通话本身没坏）。
            if settings.systemCallUI, let why = SystemCall.lastFailure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11.5, weight: .medium))
                    Text(why)
                        .font(.aevis(11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .aevisGlass(cornerRadius: 12)
            }

            // ⚠️ 顺序很重要：**先看 `lastSaid`，再看 `thinking`**。
            //    她的话现在（2026-10-01）是**边收边显示**的 —— 流式的第一个字一到，
            //    `lastSaid` 就不空了。这时候再显示「正在想…」的转圈，
            //    等于把她刚开始说的字盖掉，那几秒看起来还是"卡住"。
            if !call.lastSaid.isEmpty {
                Text(call.lastSaid)
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .aevisGlass(cornerRadius: 16)
            } else if call.thinking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("\(Pronoun.current)正在想…")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                }
            }

            // 你正在说的 —— 让她听到了什么，你看得见
            if !call.listeningText.isEmpty {
                Text("「\(call.listeningText)」")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if call.state == .active && !call.muted {
                Text(call.thinking ? " " : "在听…")
                    .font(.aevis(12.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 92, alignment: .center)
        .padding(.horizontal, 4)
    }

    // MARK: - 打字发言

    /// 通话里那个输入框 —— 说不出口的可以打出来。
    ///
    /// 和说话**走的是同一条路**（`CallService.send` → 同一个 `respond`），
    /// 所以她该记得的照样记得、该落进聊天记录的照样落。
    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("打字说…", text: $draft, axis: .vertical)
                .font(.aevis(14.5))
                .foregroundStyle(.primary)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .focused($typing)
                .onSubmit(sendTyped)

            Button(action: sendTyped) {
                Image(systemName: "arrow.up")
                    .font(.aevis(15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? settings.accentColor : Color.primary.opacity(0.15)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeOut(duration: 0.15), value: canSend)
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .aevisGlass(cornerRadius: 20)
        .padding(.top, 12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendTyped() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await call.send(text: text) }
    }

    // MARK: - 按钮

    private var controls: some View {
        // ⚠️ 三个按钮的间距从 40 收到 26 —— 62 pt 一个圆钮，40 的间距在
        //    iPhone 上会把「挂断」顶到屏幕边上（还挤掉了呼吸感）。
        HStack(spacing: 26) {
            roundButton(
                symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                label: call.muted ? "已静音" : "静音",
                tint: call.muted ? Color.orange : Color.primary
            ) {
                call.toggleMute()
            }

            // 免提（用户 2026-10-01：「加点功能」）。
            // ⚠️ 只改意图，路由由 `AudioSession` 落 —— 会话是全进程唯一的。
            roundButton(
                symbol: "speaker.wave.3.fill",
                label: call.speakerOn ? "免提" : "听筒",
                tint: call.speakerOn ? settings.accentColor : Color.primary
            ) {
                call.toggleSpeaker()
            }

            roundButton(
                symbol: "phone.down.fill",
                label: "挂断",
                tint: Color.white,
                background: Color.red
            ) {
                call.hangUp()
                dismiss()
            }
        }
        .padding(.top, 18)
    }

    private func roundButton(
        symbol: String,
        label: String,
        tint: Color,
        background: Color = Color.primary.opacity(0.08),
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 7) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.aevis(20, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(background))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Text(label)
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
        }
    }
}
