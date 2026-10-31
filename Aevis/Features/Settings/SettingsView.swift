import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

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
    /// 「运行记录」（黑匣子）那块复制完的小提示。
    @State private var diagnosticsNote: String?
    @State private var showClearConfirm = false
    @State private var pullingModels = false
    @State private var modelMessage: String?
    @State private var newSourceName = ""
    @State private var newSourceTemplate = ""
    /// 折起来的组。默认空 = **全部展开**（理由见下面 sections 的注释）。
    @State private var folded: Set<String> = []
    /// 截图自检用：带 `-aevisOpenConsole` 启动时，**自动**把命令台那一页推出来。
    ///
    /// 为什么需要它：命令台藏在设置页那张卡的 `NavigationLink` 后面，
    /// 光带 `-aevisOpenSettings -aevisSettingsFocus=console` **只停在设置页、
    /// 只高亮那张卡**，进不去 ⇒ 以前一个包都没有命令台的截图。见下面 consoleCard。
    @State private var autoConsole = false

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
                Text("ta 会忘掉你们聊过的一切。这个操作不能撤销。")
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
            CardSection(id: "her", title: "\(Pronoun.current)",
                        keys: ["persona", "voice", "memory", "moments", "proactive"]),
            CardSection(id: "chat", title: "聊天",
                        keys: ["myprofile", "bubbles", "emoji", "chat"]),
            CardSection(id: "look", title: "外观",
                        keys: ["appearance"]),
            CardSection(id: "brain", title: "模型与联网",
                        keys: ["model", "search"]),
            CardSection(id: "power", title: "能力",
                        // 「AI 权限」排在最前：它是这一组的总闸，
                        // 其余那些能力都归它管，放中间会让人以为只是并列的一项。
                        // 🚀 「微信机器人」提到第 2 位（2026-10-07）：老板反馈在设置页里
                        //    找不到它（原来夹在 qqbot 后面），所以挪到最显眼处，
                        //    一眼就能看到。其余 key 的顺序、名字一个都没动。
                        keys: ["aitools", "wechatbot", "companion", "baidupan", "music",
                               "qqbot", "qq", "system", "mcp", "console"]),
            CardSection(id: "data", title: "账号与数据",
                        keys: ["account", "device", "devicelist", "pair", "share", "about"])
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
        case "appearance":
            // ⚠️ **两种进入方式给的东西不一样**（用户 2026-09-28 的要求：
            //    「在特定的页面只展示特定的设置，砍掉其他设置，但是功能还是在的，
            //      在总设置里还是会展现」）：
            //    · 从「我」那一页的「外观」**直达**进来 → 只给聊天背景 + 气泡圆角
            //    · 走「设置」整页 → 完整 7 组（主题色/字体/图标/玻璃/简易模式都在）
            AppearanceSettingsCard(chatOnly: activeFocus != nil)
        case "memory": MemoryCard()
        case "moments": MomentsCard()
        case "companion": CompanionCard()
        case "aitools": AIToolsCard()
        case "proactive": ProactiveSettingsCard()
        case "voice": VoiceSettingsCard()
        case "music": musicCard
        case "console": consoleCard
        case "model": modelCard
        case "search": searchCard
        case "qq": QQCard()
        case "qqbot": QQBotCard()
        case "wechatbot": WeChatBotCard()
        case "account": AccountCard()
        case "device": DeviceCard()
        case "devicelist": DeviceListCard()
        case "pair": PairCard()
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
                // 折叠/展开是设置页上最常点的东西，记一笔 ——
                // 查现场时能知道"他那会儿在翻哪一组设置"。
                BlackBox.tap("设置分组 · \(isFolded(section.id) ? "展开" : "折叠")\(section.title)")
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

    // MARK: - ta

    private var personaCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("ta")

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
                        Text("\(Pronoun.current)也能用命令行帮你干活")
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
        // 截图自检直达：带 `-aevisOpenConsole` 启动时，把命令台那一页自动推出来。
        // ⚠️ 用 `navigationDestination(isPresented:)`，**不要**用 `NavigationLink(isActive:)`
        //    —— 后者在 NavigationStack（iOS 16+）里已废弃、会静默不生效。
        //    这个写法与同目录的 MemoryCard（`-aevisOpenMemoryList`）一致，
        //    是这套代码里现成跑通的路子。
        .navigationDestination(isPresented: $autoConsole) {
            ConsoleView()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenConsole") {
                autoConsole = true
            }
            #endif
        }
    }

    // MARK: - 模型接入

    // MARK: - API 预设
    //
    // 用户口径：「每个 App 可以添加很多个 API 商家，然后能收藏这些 API，有记忆的 API，
    // 可以自定义很多个，一个预设等于一个 API」。
    //
    // 所以这一块只干两件事：**列出所有预设** + **点一下切过去**。
    // 改具体内容（地址 / 模型 / Key）还是用下面那三栏 —— 免得同一个字段有两套输入框。
    /// 云端模型列表（模型 + 积分单价由后端下发）
    @ObservedObject private var cloudModels = CloudModelStore.shared

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle("模型接入")

            // ★ 2026-10-31：云端模型 —— 不再让用户填 API Key / 接口地址。
            //    聊天统一走我们的云端网关（`/v1/llm/chat`），按 token 扣积分，
            //    价格 = DeepSeek 官方价 × 1.5。用户只负责「选哪个模型」。
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("云端模型")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if cloudModels.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await cloudModels.refresh(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(cloudModels.models) { m in
                    Button {
                        cloudModels.selectedID = m.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: cloudModels.selectedID == m.id
                                  ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 17))
                                .foregroundStyle(cloudModels.selectedID == m.id
                                                 ? settings.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(m.label)
                                        .font(.aevis(14, weight: .medium))
                                    if m.isDefault {
                                        Text("推荐")
                                            .font(.aevis(10, weight: .medium))
                                            .foregroundStyle(settings.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(settings.accentColor.opacity(0.14)))
                                    }
                                }
                                if !m.note.isEmpty {
                                    Text(m.note)
                                        .font(.aevis(11.5))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(m.priceHint)
                                    .font(.aevis(11))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if cloudModels.models.isEmpty {
                    Text("正在取模型列表…")
                        .font(.aevis(12))
                        .foregroundStyle(.tertiary)
                }

                Text("聊天按 token 计费，从积分里扣。价格 = DeepSeek 官方价 × 1.5，"
                     + "1 元 = 200 积分。积分不够会提示你去充值。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            rule

            // ⚠️ hint 别写死成 `deepseek-chat`（2026-10-07 改）——
            //    那个模型名已于 2026-07-24 停用，写在那儿等于**教用户填一个已经死掉的**名字。

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
                    Text("带太多\(Pronoun.current)会又慢又贵，太少\(Pronoun.current)会失忆。25 条左右是个平衡点。")
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

                Text("不需要填 Key —— 登录账号就能用，费用从积分里扣。"
                     + "Key 只在服务器上，你手机里不存任何第三方密钥。")
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

                Text("必应是默认，前一个引擎搜不到会自动换下一个兜底。你自己加的源排在最前，全都抓不出结果时，\(Pronoun.current)会把正文读给你 —— 不会白跑一趟。")
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

            diagnosticsBlock

        }
        .padding(.bottom, 4)
        .aevisGlass(cornerRadius: 20)
    }

    /// 「运行记录」—— 黑匣子的出口。
    ///
    /// ## 为什么必须有一块这个
    /// 用户连着报闪退（点歌、通话、网易云搜索），而**我拿不到任何现场**：
    /// 他不会去翻系统日志，我也没法在他手机上复现（本机没有 Xcode）。
    /// 前两轮只能靠读代码猜，猜错过。
    ///
    /// 所以给他一个**点得动**的按钮：出问题的时候复制一段文本发过来，
    /// 我就能看见死在哪一步、是哪个接口的什么错误。
    ///
    /// 放在「关于」里而不是主界面：它是排查用的，不该摆在明面上让人困惑。
    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 16)

            HStack(spacing: 8) {
                Text("运行记录")
                    .font(.aevis(13.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if BlackBox.crashedLastRun {
                    Text("上次异常退出")
                        .font(.aevis(12, weight: .medium))
                        .foregroundStyle(Color.orange)
                } else {
                    Text("\(BlackBox.recent.count) 行")
                        .font(.aevis(12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)

            Text(BlackBox.crashedLastRun
                 ? "上次 App 是异常结束的（崩了，或者被上滑关掉）。点「复制诊断信息」把现场发出来 —— 里面记着最后那几十步是什么。"
                 : "闪退和接口报错都会记在这儿。App 出问题的时候，点「复制诊断信息」发给卖你的人就行。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Button {
                    copyDiagnostics()
                } label: {
                    Text("复制诊断信息")
                        .font(.aevis(13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)

                Button {
                    BlackBox.clear()
                    diagnosticsNote = "记录清空了。"
                } label: {
                    Text("清空")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            if let diagnosticsNote {
                Text(diagnosticsNote)
                    .font(.aevis(11.5))
                    .foregroundStyle(Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 13)
    }

    private func copyDiagnostics() {
        #if canImport(UIKit)
        UIPasteboard.general.string = BlackBox.report()
        diagnosticsNote = "复制好了 —— 粘给卖你的人就行。"
        BlackBox.log("（导出了一份诊断信息）")
        #endif
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
                testResult = "连接正常，ta 说：「\(reply)」"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }

    /// 刷新云端模型列表。
    ///
    /// ★ 2026-10-31：模型清单现在由**我们自己的云端**下发
    ///   （`/v1/llm/models`），不再问第三方接口要 —— 所以这里只调云端。
    private func pullModels() {
        pullingModels = true
        modelMessage = nil
        Task { @MainActor in
            await cloudModels.refresh(force: true)
            modelMessage = cloudModels.lastError.isEmpty
                ? "云端有 \(cloudModels.models.count) 个模型可选。"
                : "取模型列表失败：\(cloudModels.lastError)"
            pullingModels = false
        }
    }
}
