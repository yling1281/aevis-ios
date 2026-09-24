import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var chat: ChatStore

    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    personaCard
                    modelCard
                    speechCard
                    chatCard
                    diagnosticsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "清空所有对话记录？",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) { chat.clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("她会忘掉你们聊过的一切。这个操作不能撤销。")
            }
        }
    }

    // MARK: - 她的设定

    private var personaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("她")

            NavigationLink {
                PersonaEditorView(isFirstRun: false)
            } label: {
                HStack(spacing: 12) {
                    AevisAvatar(size: 40, seed: personaStore.persona.avatarSeed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(personaStore.persona.name.isEmpty ? "还没起名字" : personaStore.persona.name)
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("名字、性格、说话方式、声音")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 模型接入

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("模型接入")

            labeledField("接口地址", hint: "https://api.deepseek.com/v1", text: $settings.baseURL)
            divider

            VStack(alignment: .leading, spacing: 7) {
                Text("API Key")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $settings.apiKey)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            divider

            labeledField("模型名", hint: "deepseek-chat", text: $settings.model)
            divider

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button(action: runTest) {
                        HStack(spacing: 7) {
                            if testing {
                                ProgressView().controlSize(.small)
                            }
                            Text(testing ? "正在试…" : "测试连接")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(testing)

                    Spacer(minLength: 0)
                }

                if let testResult {
                    Text(testResult)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Key 只存在这台手机的钥匙串里，不会上传到任何地方，也不会进代码仓库。支持任何 OpenAI 兼容接口。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 说话

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("说话")

            HStack {
                Text("她回复时念出来")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Toggle("", isOn: $settings.speakerEnabled)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            divider

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
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 对话

    private var chatCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("对话")

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已记住 \(chat.messages.count) 条消息")
                        .font(.system(size: 14.5))
                        .foregroundStyle(.primary)
                    Text("记录只存在这台手机上")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("清空") { showClearConfirm = true }
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .disabled(chat.messages.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 关于本机

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("关于本机")

            ForEach(Array(diagnosticRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if index < diagnosticRows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.bottom, 4)
        .aevisGlass(cornerRadius: 20)
    }

    private var diagnosticRows: [(String, String)] {
        [
            ("系统版本", Diagnostics.osVersion),
            ("设备代号", Diagnostics.machine),
            ("App 版本", Diagnostics.appVersion),
            ("构建提交", Diagnostics.commit),
            ("液态玻璃", Diagnostics.supportsLiquidGlass ? "可用" : "不可用"),
            ("签名状态", Diagnostics.isSigned ? "已签名" : "未签名"),
            ("内置 Linux", Diagnostics.hasLinuxSandbox ? "已就绪" : "未接入")
        ]
    }

    // MARK: - 零件

    private func cardTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func labeledField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func runTest() {
        testing = true
        testResult = nil
        let config = settings.llm

        Task { @MainActor in
            do {
                let reply = try await LLMService.probe(config: config)
                testResult = "连接正常，她说：「\(reply)」"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
