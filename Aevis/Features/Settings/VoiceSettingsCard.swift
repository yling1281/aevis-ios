import SwiftUI

/// 「声音」设置卡片：系统音色 / 外部 API 两种来源，外接支持从接口拉取音色清单。
struct VoiceSettingsCard: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var pullingVoices = false
    @State private var pullMessage: String?
    @State private var manualVoice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("声音")

            toggleRow("回复后直接念出来", isOn: $settings.speakerEnabled)
            rule

            VStack(alignment: .leading, spacing: 9) {
                label("语音来源")
                Picker("语音来源", selection: $settings.ttsMode) {
                    ForEach(TTSMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            rule

            if settings.ttsMode == .system {
                systemSection
            } else {
                remoteSection
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 系统音色

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("语速")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(String(format: "%.2f", settings.speechRate))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $settings.speechRate, in: 0.3...0.7)

            Text("免费、离线、不花钱。想更好听：设置 → 辅助功能 → 朗读内容 → 声音 → 中文，下载「增强」或「高级」音色，下完「TA 的设定」里的音色列表会多出来。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 外部 API

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("接口地址", hint: "留空 = 沿用模型接口", text: $settings.ttsBaseURL)

            secureField("API Key", hint: "留空 = 沿用模型 Key", text: $settings.ttsAPIKey)

            field("模型名", hint: "tts-1", text: $settings.ttsModel)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Button(action: pullVoices) {
                        HStack(spacing: 7) {
                            if pullingVoices {
                                ProgressView().controlSize(.small)
                            }
                            Text(pullingVoices ? "正在拉…" : "拉取音色")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(pullingVoices)

                    Button(action: preview) {
                        Text("试听")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Spacer(minLength: 0)
                }

                if !settings.ttsVoices.isEmpty {
                    Picker("音色", selection: $settings.ttsVoice) {
                        Text("未选择").tag("")
                        ForEach(settings.ttsVoices, id: \.self) { voice in
                            Text(voice).tag(voice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    TextField("也可以手填音色 ID，例如 alloy", text: $manualVoice)
                        .font(.system(size: 13.5))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    Button("使用") {
                        let value = manualVoice.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        settings.ttsVoice = value
                        if !settings.ttsVoices.contains(value) {
                            settings.ttsVoices.append(value)
                        }
                        manualVoice = ""
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                }

                if let pullMessage {
                    Text(pullMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("走的是 OpenAI 兼容的 /audio/speech。地址和 Key 留空时会自动沿用上面「模型接入」里那套，大多数中转站不用重复填。外接失败会自动退回系统音色，不会让 TA 突然哑掉。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("语速")
                        .font(.system(size: 14.5))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.2f", settings.speechRate))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.speechRate, in: 0.3...0.7)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 动作

    private func pullVoices() {
        pullingVoices = true
        pullMessage = nil
        let config = settings.tts

        Task { @MainActor in
            do {
                let (entries, fromAPI) = try await ModelCatalog.fetchVoices(config: config)
                settings.ttsVoices = entries.map(\.id)
                if settings.ttsVoice.isEmpty {
                    settings.ttsVoice = entries.first?.id ?? ""
                }
                pullMessage = fromAPI
                    ? "拉到 \(entries.count) 个音色。"
                    : "这个接口没提供音色清单，已放上内置的 OpenAI 系常见音色。也可以在下面手填。"
            } catch {
                pullMessage = error.localizedDescription
            }
            pullingVoices = false
        }
    }

    private func preview() {
        pullMessage = nil
        SpeechService.shared.speak(
            "你好呀，我是你的 Aevis。",
            config: settings.tts,
            systemVoiceIdentifier: ""
        ) { message in
            pullMessage = "外接语音失败，已退回系统音色：\(message)"
        }
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
    }

    private func toggleRow(_ text: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 14.5))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func field(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label(title)
            TextField(hint, text: text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private func secureField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            label(title)
            SecureField(hint, text: text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }
}
