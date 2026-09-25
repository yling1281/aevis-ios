import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var chat: ChatStore

    /// 音乐卡片要显示"正在放什么"，所以得盯着播放器。
    @ObservedObject private var player = MusicPlayer.shared

    /// 只显示某一张卡（「我」那一页的直达入口用）。
    /// 不给就是整页 —— 跟以前一样。
    var focus: String? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var showClearConfirm = false
    @State private var pullingModels = false
    @State private var modelMessage: String?
    @State private var newSourceName = ""
    @State private var newSourceTemplate = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if shows("persona") { personaCard }
                    if shows("myprofile") { MyProfileCard() }
                    if shows("bubbles") { BubbleSettingsCard() }
                    if shows("emoji") { EmojiCard() }
                    if shows("appearance") { AppearanceSettingsCard() }
                    if shows("memory") { MemoryCard() }
                    if shows("moments") { MomentsCard() }
                    if shows("companion") { CompanionCard() }
                    if shows("proactive") { ProactiveSettingsCard() }
                    if shows("voice") { VoiceSettingsCard() }
                    if shows("music") { musicCard }
                    if shows("douyin") { DouyinCard() }
                    if shows("console") { consoleCard }
                    if shows("model") { modelCard }
                    if shows("search") { searchCard }
                    if shows("baidupan") { BaiduPanCard() }
                    if shows("system") { SystemBridgeCard() }
                    if shows("mcp") { MCPCard() }
                    if shows("chat") { chatCard }
                    if shows("about") { aboutCard }
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

    // MARK: - 截图自检用
    //
    // 设置页太长，一屏截不全。带 `-aevisSettingsFocus=<名字>` 启动时只显示那一张卡，
    // 这样 CI 不用滚屏也能把每张卡截清楚。（只在 Debug 构建里生效。）

    /// 两个来源：从「我」那一页点进来的 `focus`，或者截图自检的启动参数。
    private var activeFocus: String? {
        if let focus { return focus }
        return focusCard
    }

    private var focusCard: String? {
        #if DEBUG
        let prefix = "-aevisSettingsFocus="
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count))
        }
        #endif
        return nil
    }

    private func shows(_ name: String) -> Bool {
        guard let activeFocus else { return true }
        return activeFocus == name
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

    // MARK: - 音乐

    private var musicCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("音乐")

            NavigationLink {
                MusicView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(settings.accentColor)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(settings.accentColor.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current.map { $0.title } ?? "网易云音乐")
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(
                            NeteaseClient.shared.isLoggedIn
                                ? (player.current.map { $0.display } ?? "已登录，可以搜歌和一起听")
                                : "还没登录，点进去贴 Cookie"
                        )
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if player.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 14))
                            .foregroundStyle(settings.accentColor)
                    }
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

    // MARK: - 命令台

    private var consoleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("命令台")

            NavigationLink {
                ConsoleView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(settings.accentColor)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(settings.accentColor.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Shell.provider.displayName)
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("她也能用命令行帮你干活")
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

            // 供应商预设：切一下就自动填好地址和模型名，不用手打 URL
            VStack(alignment: .leading, spacing: 9) {
                Text("供应商")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ProviderPreset.allCases) { preset in
                            Button {
                                settings.providerPreset = preset
                                if preset != .custom {
                                    settings.baseURL = preset.baseURL
                                    if !preset.defaultModel.isEmpty {
                                        settings.model = preset.defaultModel
                                    }
                                    settings.modelList = []
                                }
                                modelMessage = "已切成「\(preset.label)」，去 \(preset.keyHint) 拿 Key。"
                            } label: {
                                Text(preset.label)
                                    .font(.aevis(13, weight: .medium))
                                    .foregroundStyle(
                                        settings.providerPreset == preset ? Color.white : Color.primary
                                    )
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule().fill(
                                            settings.providerPreset == preset
                                                ? settings.accentColor
                                                : Color.primary.opacity(0.07)
                                        )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text("预设只是帮你把地址和模型名填好，下面两栏随时能改。Key 从 \(settings.providerPreset.keyHint) 拿。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            rule

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

            // 推理预算 + 上下文 + 启动自检
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("推理预算")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(settings.reasoningBudget.explanation)
                            .font(.aevis(11))
                            .foregroundStyle(.tertiary)
                    }
                    Picker("推理预算", selection: $settings.reasoningBudget) {
                        ForEach(ReasoningBudget.allCases) { budget in
                            Text(budget.label).tag(budget)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("带上多少条历史")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("\(settings.contextLimit) 条")
                            .font(.aevis(12.5))
                            .foregroundStyle(.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.contextLimit) },
                            set: { settings.contextLimit = Int($0) }
                        ),
                        in: 6...200,
                        step: 2
                    )
                    Text("带太多她会又慢又贵，太少她会失忆。40 左右是个平衡点。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启动时自动测连接")
                            .font(.aevis(14.5))
                            .foregroundStyle(.primary)
                        Text("不通就直接告诉你，免得对着一句没反应的对话框猜")
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $settings.autoTestOnLaunch)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
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

    // MARK: - 搜索源

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("联网搜索源")

            VStack(alignment: .leading, spacing: 10) {
                ForEach(settings.searchSources) { source in
                    HStack(spacing: 10) {
                        Button {
                            settings.activeSearchSource = source.name
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: settings.activeSearchSource == source.name
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 15))
                                    .foregroundStyle(
                                        settings.activeSearchSource == source.name
                                            ? settings.accentColor : Color.secondary
                                    )
                                Text(source.name)
                                    .font(.aevis(14.5))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if settings.searchSources.count > 1 {
                            Button {
                                settings.searchSources.removeAll { $0.name == source.name }
                                if settings.activeSearchSource == source.name {
                                    settings.activeSearchSource = settings.searchSources.first?.name ?? ""
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("新源的名字（例如 豆包）", text: $newSourceName)
                        .font(.aevis(13.5))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    TextField("地址模板，用 {q} 代表关键词", text: $newSourceTemplate)
                        .font(.aevis(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    Button {
                        addSearchSource()
                    } label: {
                        Text("加到列表")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }
                }

                Text("必应是默认。加了别的源之后，如果那个页面抓不出结果列表，她会直接把正文读给你 —— 不会白跑一趟。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func addSearchSource() {
        let name = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let template = newSourceTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, template.contains("{q}") else {
            modelMessage = "搜索源要有名字，而且地址模板里必须包含 {q}。"
            return
        }
        guard !settings.searchSources.contains(where: { $0.name == name }) else {
            modelMessage = "已经有一个叫「\(name)」的搜索源了。"
            return
        }
        settings.searchSources.append(SearchSource(name: name, template: template))
        settings.activeSearchSource = name
        newSourceName = ""
        newSourceTemplate = ""
        modelMessage = "加好了，并且已经切到「\(name)」。"
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
        // 正式版只留用户看得懂的：版本 / 构建 / 运行环境。
        // 「液态玻璃可用」「签名」「内置 Linux」是**开发排查用的**，摆在这里只会
        // 让人困惑（用户直接问过「为什么还是有液态玻璃可用之类的」），
        // 所以它们只在 Debug 构建里出现。
        var rows: [(String, String)] = [
            ("版本", Diagnostics.appVersion),
            ("构建", Diagnostics.commit),
            ("运行环境", "iOS \(Diagnostics.osVersion) · \(Diagnostics.machine)")
        ]
        #if DEBUG
        rows.append(("液态玻璃", Diagnostics.supportsLiquidGlass ? "可用" : "不可用"))
        rows.append(("签名", Diagnostics.isSigned ? "已签名" : "未签名"))
        rows.append(("内置 Linux", Diagnostics.hasLinuxSandbox ? "已就绪" : "未接入"))
        #endif
        return rows
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
