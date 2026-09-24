import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var chat: ChatStore

    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var showClearConfirm = false
    @State private var pullingModels = false
    @State private var modelMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    personaCard
                    AppearanceSettingsCard()
                    VoiceSettingsCard()
                    modelCard
                    chatCard
                    aboutCard
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
                Text("TA 会忘掉你们聊过的一切。这个操作不能撤销。")
            }
        }
    }

    // MARK: - TA

    private var personaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("TA")

            NavigationLink {
                PersonaEditorView(isFirstRun: false)
            } label: {
                HStack(spacing: 12) {
                    AevisAvatar(size: 40, seed: personaStore.persona.avatarSeed)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(personaStore.persona.name.isEmpty ? "还没起名字" : personaStore.persona.name)
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("头像、名字、性别、性格、说话方式、系统音色")
                            .font(.aevis(12))
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
            rule

            VStack(alignment: .leading, spacing: 7) {
                Text("API Key")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                SecureField("sk-...", text: $settings.apiKey)
                    .font(.aevis(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(fieldBackground)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            rule

            labeledField("模型名", hint: "deepseek-chat", text: $settings.model)
            rule

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(action: runTest) {
                        HStack(spacing: 7) {
                            if testing {
                                ProgressView().controlSize(.small)
                            }
                            Text(testing ? "正在试…" : "测试连接")
                                .font(.aevis(14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(testing)

                    Button(action: pullModels) {
                        HStack(spacing: 7) {
                            if pullingModels {
                                ProgressView().controlSize(.small)
                            }
                            Text(pullingModels ? "正在拉…" : "拉取模型")
                                .font(.aevis(14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(pullingModels)

                    Spacer(minLength: 0)
                }

                if let testResult {
                    Text(testResult)
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let modelMessage {
                    Text(modelMessage)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 拉到的模型：做成可点的列表，一眼看得出哪个在用。
                // 之前用下拉菜单，在 iOS 上只渲染出一个很小的箭头，看着像坏了。
                if !settings.modelList.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("选一个")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)

                        ForEach(settings.modelList, id: \.self) { name in
                            Button {
                                settings.model = name
                            } label: {
                                HStack(spacing: 10) {
                                    Text(name)
                                        .font(.aevis(14))
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    if settings.model == name {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(settings.accentColor)
                                    }
                                }
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("Key 只存在这台手机的钥匙串里，不会上传到任何地方，也不会进代码仓库。支持任何 OpenAI 兼容接口。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)
                    Text("记录只存在这台手机上")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("清空") { showClearConfirm = true }
                    .font(.aevis(14))
                    .foregroundStyle(.red)
                    .disabled(chat.messages.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 关于 Aevis

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 这里不是 iOS 的「关于本机」，是 Aevis 自己的版本信息，
            // 叫法上分开，免得看着像系统设置。
            cardTitle("关于 Aevis")

            ForEach(Array(aboutRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.aevis(13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if index < aboutRows.count - 1 {
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

    private var aboutRows: [(String, String)] {
        [
            ("版本", Diagnostics.appVersion),
            ("构建", Diagnostics.commit),
            ("运行环境", "iOS \(Diagnostics.osVersion) · \(Diagnostics.machine)"),
            ("液态玻璃", Diagnostics.supportsLiquidGlass ? "可用" : "不可用"),
            ("签名", Diagnostics.isSigned ? "已签名" : "未签名"),
            ("内置 Linux", Diagnostics.hasLinuxSandbox ? "已就绪" : "未接入")
        ]
    }

    // MARK: - 零件

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.primary.opacity(0.05))
    }

    private func cardTitle(_ text: String) -> some View {
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

    private func labeledField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
            TextField(hint, text: text)
                .font(.aevis(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(fieldBackground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 动作

    private func runTest() {
        testing = true
        testResult = nil
        let config = settings.llm

        Task { @MainActor in
            do {
                let reply = try await LLMService.probe(config: config)
                testResult = "连接正常，TA 说：「\(reply)」"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func pullModels() {
        pullingModels = true
        modelMessage = nil
        let config = settings.llm

        Task { @MainActor in
            do {
                let entries = try await ModelCatalog.fetchModels(config: config)
                settings.modelList = entries.map(\.id)
                modelMessage = entries.isEmpty
                    ? "接口没返回模型清单，可以直接手填模型名。"
                    : "拉到 \(entries.count) 个模型。"
            } catch {
                modelMessage = error.localizedDescription
            }
            pullingModels = false
        }
    }
}
