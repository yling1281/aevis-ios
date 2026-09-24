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

                controls
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .task {
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

            TimelineView(.periodic(from: .now, by: 1)) { _ in
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

            if call.thinking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("她正在想…")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                }
            } else if !call.lastSaid.isEmpty {
                Text(call.lastSaid)
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .aevisGlass(cornerRadius: 16)
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

    // MARK: - 按钮

    private var controls: some View {
        HStack(spacing: 40) {
            roundButton(
                symbol: call.muted ? "mic.slash.fill" : "mic.fill",
                label: call.muted ? "已静音" : "静音",
                tint: call.muted ? Color.orange : Color.primary
            ) {
                call.toggleMute()
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
