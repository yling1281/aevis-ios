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
    /// 折起来的组。默认空 = **全部展开**（理由见下面 sections 的注释）。
    @State private var folded: Set<String> = []
    // —— API 预设 ——
    @State private var showNewProfile = false
    @State private var newProfileName = ""
    @State private var editingProfileID = ""
    @State private var renameDraft = ""
    @State private var renameNote = ""
    @State private var deleteTarget: APIProfile?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let activeFocus {
                    // 「我」那一页点进来的**直达模式**：只显示那一张卡。
                    // 否则用户为了改一项，还要在 20 多张卡里再找一遍。
                    card(activeFocus)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(sections) { section in
                            sectionView(section)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
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

    // MARK: - 分组
    //
    // 以前是 20 多张卡**平铺**成一条很长的页，用户同一件事要在「我」和这里各找一遍。
    // 现在收成 6 组，组头能折起来。
    //
    // ⚠️ **默认全部展开**。折叠是为了让人一眼看清结构，**不是为了把东西藏起来** ——
    // 藏起来的功能在用户眼里等于没做（这一条栽过两次了）。

    private struct CardSection: Identifiable {
        let id: String
        let title: String
        let keys: [String]
    }

    private var sections: [CardSection] {
        [
            CardSection(id: "her", title: "她",
                        keys: ["persona", "voice", "memory", "moments", "proactive"]),
            CardSection(id: "chat", title: "聊天",
                        keys: ["myprofile", "bubbles", "emoji", "chat"]),
            CardSection(id: "look", title: "外观",
                        keys: ["appearance"]),
            CardSection(id: "brain", title: "模型与联网",
                        keys: ["model", "search"]),
            CardSection(id: "power", title: "能力",
                        keys: ["companion", "baidupan", "music", "douyin",
                               "qqbot", "qq", "system", "mcp", "console"]),
            CardSection(id: "data", title: "账号与数据",
                        keys: ["account", "device", "share", "about"])
        ]
    }

    /// 键 → 卡片。**一处定义，两处用**（分组页 / 直达模式），
    /// 免得以后加卡片时只改了一边（那种漏很难发现）。
    @ViewBuilder
    private func card(_ key: String) -> some View {
        switch key {
        case "persona": personaCard
        case "myprofile": MyProfileCard()
        case "bubbles": BubbleSettingsCard()
        case "emoji": EmojiCard()
        case "appearance": AppearanceSettingsCard()
        case "memory": MemoryCard()
        case "moments": MomentsCard()
        case "companion": CompanionCard()
        case "proactive": ProactiveSettingsCard()
        case "voice": VoiceSettingsCard()
        case "music": musicCard
        case "douyin": DouyinCard()
        case "console": consoleCard
        case "model": modelCard
        case "search": searchCard
        case "qq": QQCard()
        case "qqbot": QQBotCard()
        case "account": AccountCard()
        case "device": DeviceCard()
        case "share": ShareCard()
        case "baidupan": BaiduPanCard()
        case "system": SystemBridgeCard()
        case "mcp": MCPCard()
        case "chat": chatCard
        case "about": aboutCard
        default: EmptyView()
        }
    }

    private func sectionView(_ section: CardSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { toggle(section.id) }
            } label: {
                HStack(spacing: 6) {
                    Text(section.title)
                        .font(.aevis(13.5, weight: .semibold))
                        .foregroundStyle(.primary)

                    Image(systemName: "chevron.down")
                        .font(.aevis(11, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isFolded(section.id) ? -90 : 0))

                    Spacer(minLength: 0)

                    Text("\(section.keys.count) 项")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)

            if !isFolded(section.id) {
                VStack(spacing: 16) {
                    ForEach(section.keys, id: \.self) { key in
                        card(key)
                    }
                }
            }
        }
    }

    private func isFolded(_ id: String) -> Bool { folded.contains(id) }

    private func toggle(_ id: String) {
        if folded.contains(id) { folded.remove(id) } else { folded.insert(id) }
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

    // MARK: - API 预设
    //
    // 用户口径：「每个 App 可以添加很多个 API 商家，然后能收藏这些 API，有记忆的 API，
    // 可以自定义很多个，一个预设等于一个 API」。
    //
    // 所以这一块只干两件事：**列出所有预设** + **点一下切过去**。
    // 改具体内容（地址 / 模型 / Key）还是用下面那三栏 —— 免得同一个字段有两套输入框。

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("我的 API 预设")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("存为预设") {
                    newProfileName = ""
                    showNewProfile = true
                }
                .font(.aevis(12.5))
                .buttonStyle(.borderless)
            }

            if settings.apiProfiles.isEmpty {
                Text("还没有预设。把现在这套「存为预设」起个名字，以后填别的商家再存一套，"
                     + "就能一键切换 —— 地址、模型、Key 会一起换过去。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(settings.sortedProfiles) { profile in
                    profileRow(profile)
                }
                Text("点一行就切过去；长按可以收藏、改名、复制、删除。收藏的排在前面。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .alert("存为预设", isPresented: $showNewProfile) {
            TextField("给它起个名字，比如「DeepSeek 主号」", text: $newProfileName)
            Button("保存") {
                settings.saveCurrentAsProfile(name: newProfileName)
                newProfileName = ""
                modelMessage = "存好了。以后切别的商家时，点一下就能换回来。"
            }
            Button("取消", role: .cancel) { newProfileName = "" }
        } message: {
            Text("会记住当前的地址、模型和 Key。")
        }
        .alert("改名 / 备注", isPresented: Binding(
            get: { !editingProfileID.isEmpty },
            set: { if !$0 { editingProfileID = "" } }
        )) {
            TextField("名字", text: $renameDraft)
            TextField("备注（可留空）", text: $renameNote)
            Button("保存") {
                settings.renameProfile(editingProfileID, to: renameDraft, note: renameNote)
                editingProfileID = ""
            }
            Button("取消", role: .cancel) { editingProfileID = "" }
        } message: {
            Text("备注是给你自己看的，比如「余额 20」「便宜但慢」。")
        }
        .alert("删除这个预设？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let target = deleteTarget { settings.deleteProfile(target.id) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("只删掉这套预设（名字、地址、Key）。聊天记录和别的设置都不受影响。")
        }
    }

    private func profileRow(_ profile: APIProfile) -> some View {
        let active = settings.activeProfileID == profile.id
        let missingKey = settings.apiKey(forProfile: profile.id)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button {
            guard !active else { return }
            settings.useProfile(profile.id)
            modelMessage = "已切到「\(profile.name)」。"
        } label: {
            HStack(spacing: 10) {
                Image(systemName: active ? "largecircle.fill.circle" : "circle")
                    .font(.aevis(15))
                    .foregroundStyle(active ? settings.accentColor : Color.secondary.opacity(0.55))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(profile.name)
                            .font(.aevis(14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if profile.favorite {
                            Image(systemName: "star.fill")
                                .font(.aevis(9.5))
                                .foregroundStyle(.yellow)
                        }
                    }
                    Text(profileSubtitle(profile))
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if missingKey {
                    Text("缺 Key")
                        .font(.aevis(11))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? settings.accentColor.opacity(0.12)
                                 : Color.primary.opacity(0.045))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                settings.toggleFavorite(profile.id)
            } label: {
                Label(profile.favorite ? "取消收藏" : "收藏（置顶）", systemImage: "star")
            }
            Button {
                renameDraft = profile.name
                renameNote = profile.note
                editingProfileID = profile.id
            } label: {
                Label("改名 / 备注", systemImage: "pencil")
            }
            Button {
                settings.duplicateProfile(profile.id)
            } label: {
                Label("复制一份", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = profile
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 一行副标题：模型 · 域名 ·（备注）。认得出是哪个商家就够了，不铺太满。
    private func profileSubtitle(_ profile: APIProfile) -> String {
        var parts: [String] = []
        if !profile.model.isEmpty { parts.append(profile.model) }
        parts.append(profile.hostLabel)
        if !profile.note.isEmpty { parts.append(profile.note) }
        return parts.joined(separator: " · ")
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("模型接入")

            // 我的 API 预设放在最上头 —— 用户要的「能加很多个商家、能收藏、有记忆」
            // 就是这一块。它管的是"用哪一套"，下面三栏是"这一套具体长什么样"。
            profileSection
            rule

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

                Text("预设只是帮你把地址和模型名填好，下面两栏随时能改。"
                     + "改了会存进「当前那套」预设 —— 想试别的又不想动现在这套，"
                     + "先长按「复制一份」。Key 从 \(settings.providerPreset.keyHint) 拿。")
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
            // 用户 2026-09-25 要求：**正式版只写版本号，"构建"那行不要**。
            // 他原话「构建的话你就不用写了，你就写个版本号就 OK 了」。
            // 之所以敢去掉：版本号（MARKETING_VERSION）每次都跟着 build 号走
            // （build-46 → 0.0.46），所以"版本号"本身就能分辨新旧。
            ("版本", Diagnostics.appVersion),
            ("运行环境", "iOS \(Diagnostics.osVersion) · \(Diagnostics.machine)")
        ]
        #if DEBUG
        // 自检截图跑的是 Debug 构建，所以那批图里仍然看得到构建号 ——
        // 排查"你手机上装的是哪一版"时，commit 才是最可靠的依据。
        rows.append(("构建", Diagnostics.commit))
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
