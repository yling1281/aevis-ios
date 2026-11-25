import SwiftUI
import AVFoundation
import Speech

/// 聊天（2026-11-17 骨架；2026-11-22 升级为流式 SSE）。
///
/// 本地历史能看、能发、括号变浅、头像/字号跟设置；回复走 SSE 逐字显示，
/// 增量到达即刷新气泡并滚动贴底；网络/格式异常有兜底与「重发」。
struct ChatView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    let persona: Persona
    #if DEBUG
    /// 137：CI 截图用的样例模式（不读写本地、不发请求）。Release 编不进去。
    var demo: Bool = false
    #endif

    /// 底部「对方发了一条动态　查看」悬浮胶囊的摘要文案。
    ///
    /// **传 nil（默认）= 没有未读动态，胶囊不渲染。**
    /// ⚠️ 数据源待接：`/v1` 目前**没有**「该人设是否有未读动态」的接口
    /// （`APIClient` 里没有任何 moment/feed 方法），所以这里不造假数据 ——
    /// 后端给出「有无未读动态 + 摘要 + 跳转 id」之后，把它传进来即可，UI 不用再改。
    var momentPrompt: String? = nil
    /// 点「查看」的动作。与 `momentPrompt` 成对出现。
    var onOpenMoment: (() -> Void)? = nil

    @State private var msgs: [Msg] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error = ""
    /// 错误分类：决定错误条右侧给什么动作（重新登录 / 去充值 / 重发）。
    @State private var errorKind: ErrorKind = .none
    /// 流式时 msgs.count 不变、content 变，靠这个 tick 触发滚动贴底。
    @State private var scrollTick = 0

    enum ErrorKind { case none, relogin, recharge, retry }

    @AppStorage("msgSize") private var msgSize = 1          // 0 小 / 1 标准 / 2 大
    @AppStorage("annotDim") private var annotDim = true
    @AppStorage("avatarMode") private var avatarMode = 0    // 0 双方 / 1 只角色 / 2 都不显示

    // MARK: - 每角色配置（模型/温度）：发送时读，UI 编辑在 CharacterSettingsView
    /// 该角色选择的模型 id；空 = 用服务端默认。按 persona.id 独立存（UserDefaults）。
    @State private var selectedModelID: String = ""
    @State private var modelDefaultID: String = "deepseek-flash"
    /// 该角色的温度（0.0–2.0，默认 1.0），按角色存。
    @State private var temperature: Double = 1.0

    /// 表情包面板：数据来自广场 `/v1/emoji/list`（先读硬缓存），不再静态占位。
    @State private var showStickerSheet = false
    @State private var stickerPacks: [APIClient.EmojiPack] = []
    @State private var stickerLoading = false
    @State private var stickerTip = ""
    /// 人设改名后本地标题跟着变（不重建 ChatView）。
    @State private var titleName = ""

    // MARK: - 语音输入（本地 ASR，2026-11-24；替代原来的 TTS）
    /// 录音/识别/权限全在这里，视图只读它的状态。
    @StateObject private var speech = SpeechInput()
    /// 手指是否按在麦克风上（判断一次「按住→松开」的完整手势）。
    @State private var micPressed = false
    /// 当前是否落在「上滑取消」区（松手就丢弃这段识别）。
    @State private var cancelZone = false

    // MARK: - 微信式滚动（2026-11-24）
    /// 当前是否贴在底部附近。只有贴底时才自动跟随新消息，用户翻历史时绝不拽回。
    @State private var atBottom = true
    /// 首次进入是否已经做过「无动画定位到底」。
    @State private var didInitialScroll = false

    /// 每角色独立的 UserDefaults key。
    private var modelKey: String { "aevisModel_\(persona.id)" }
    private var tempKey: String { "aevisTemp_\(persona.id)" }

    /// 发送时实际使用的模型 id：角色选过就用，否则用服务端默认，最后兜底 deepseek-flash。
    private var modelForPersona: String {
        let chosen = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        return modelDefaultID.isEmpty ? "deepseek-flash" : modelDefaultID
    }

    /// 三档字号（与安卓 msgSize 一致；行高 = ×1.45）
    private var fontSize: CGFloat { AE.chatFont(msgSize) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                // 用 GeometryReader 拿视口高度，配合底部哨兵算出「离底部多远」→ 判断是否贴底。
                // iOS 16 没有 onScrollGeometryChange，只能用坐标对比这一套。
                GeometryReader { geo in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(msgs) { m in
                                row(m).id(m.id)
                            }
                            if sending {
                                HStack {
                                    Text("正在输入…").font(.footnote).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                            }
                            // 底部哨兵：取它的**上沿 minY**。
                            //   · 贴底：minY ≈ 视口高 → minY-vh ≈ 0
                            //   · 上翻：minY > 视口高（哨兵被推到屏幕下方）
                            //   · 内容比屏幕短：minY < 视口高 → 负数
                            // 用 (minY - vh) < 80 判定：贴底和「短内容」都算贴底，上翻多了才算离开。
                            Color.clear
                                .frame(height: 1)
                                .id("__BOTTOM__")
                                .background(
                                    GeometryReader { g in
                                        Color.clear.preference(
                                            key: BottomEdgeKey.self,
                                            value: g.frame(in: .named("chatScroll")).minY
                                        )
                                    }
                                )
                        }
                        .padding(.vertical, 10)
                    }
                    .coordinateSpace(name: "chatScroll")
                    .onPreferenceChange(BottomEdgeKey.self) { bottomMinY in
                        atBottom = (bottomMinY - geo.size.height) < 80
                    }
                }
                // 首次进入：定位到最后一条，**不带动画**（用户明确不要「直接滑到底」的动效）
                .onChange(of: msgs.count) { _ in
                    guard let last = msgs.last else { return }
                    if !didInitialScroll {
                        proxy.scrollTo(last.id, anchor: .bottom)
                        didInitialScroll = true
                    } else if atBottom {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                // 流式增量（msgs.count 不变、content 变）：只在贴底时才跟随，
                // 用户往上翻历史看的时候绝不把他拽回底部。
                .onChange(of: scrollTick) { _ in
                    guard let last = msgs.last, atBottom else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: errorIcon)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actionButton
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
            }

            // 语音提示条（录音中「松开结束·上滑取消」；不可用/未授权时一行红字）
            if !speech.hint.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: speech.recording ? "waveform" : "exclamationmark.circle")
                        .font(.system(size: 12))
                    Text(cancelZone ? "松开手指取消" : speech.hint)
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(speech.recording ? AE.accent : Color.red)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
                .transition(.opacity)
            }

            // 底部悬浮区（2026-11-25 按用户参考图）：**不贴屏幕底**，左右各留 12pt。
            // 输入栏是 22pt 连续圆角的白色玻璃条（white 0.72），不是贴边的一条 `.regularMaterial`。
            VStack(spacing: 8) {
                // 悬浮胶囊「对方发了一条动态　查看」——没有未读动态时不渲染（不造假数据）
                if let moment = activeMomentPrompt {
                    momentPill(moment)
                }

                HStack(spacing: 10) {
                    // 左：猫咪图标（参考图此处是品牌点缀，不做按钮；表情包入口移到右侧加号）
                    AevisMascotMark(pose: .front, size: 24)
                        .accessibilityHidden(true)

                    TextField(
                        speech.recording ? "正在听你说…" : "发消息",
                        text: $input, axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .disabled(speech.recording)

                    if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 空输入：右麦 + 加号（参考图形态）
                        micGlyph
                        Button { showStickerSheet = true } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(AE.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("表情包与更多")
                    } else {
                        // 有内容：右侧换成发送键（微信式，不多占一个位置）
                        Button { Task { await send() } } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 26))
                        }
                        .buttonStyle(.plain)
                        .disabled(sending)
                        .accessibilityLabel("发送")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.adaptive(
                            dark: Color.hex(0x232630).opacity(0.72),
                            light: Color.white.opacity(0.72)
                        ))
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        // 默认跟随全局背景；设置里打开「聊天页单独设置背景」后只铺聊天专用渐变，
        // 避免花哨全局图片压住气泡文字（2026-11-24）
        .background(ChatBackground())
        // 聊天页白膜压得轻（参考图 ≈0.60）：背景图看得清，文字靠气泡承载
        .appBackgroundIntensity(AEGlass.veilChat)
        .navigationTitle(titleName.isEmpty ? persona.name : titleName)
        .navigationBarTitleDisplayMode(.inline)
        // 进聊天详情时收起底部 Dock：系统原生 tab bar 在 push 时不会自动隐藏，
        // 必须由被 push 的目的页声明；加在 ChatListView / 外层会把列表根页的 Dock 也藏掉。
        .toolbar(.hidden, for: .tabBar)
        // 2.9 返回键：系统返回箭头在部分机型/主题下不显示或点了没反应，
        // 这里给一个显式返回按钮直接调 dismiss()。**不禁用** interactivePopGesture，
        // 系统侧滑照常可用（navigationBarBackButtonHidden 只影响箭头，不影响手势）。
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("返回").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(AE.accent)
                }
                .accessibilityLabel("返回聊天列表")
            }
            // 右上角三个点：编辑人设 / 创建人设 / 角色设置
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    NavigationLink {
                        CharacterSettingsView(persona: persona, startInProfileEdit: true)
                    } label: {
                        Label("编辑当前人设", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        PersonaCreateView { _ in
                            Task { await reloadPersonaConfig() }
                        }
                        .environmentObject(session)
                    } label: {
                        Label("添加/创建人设", systemImage: "plus.circle")
                    }
                    NavigationLink {
                        CharacterSettingsView(persona: persona)
                    } label: {
                        Label("角色设置", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
                .accessibilityLabel("更多操作")
            }
        }
        .sheet(isPresented: $showStickerSheet) { stickerSheet }
        .onReceive(NotificationCenter.default.publisher(for: CharacterSettingsView.personaUpdated)) { note in
            guard let id = note.userInfo?["id"] as? String, id == persona.id,
                  let name = note.userInfo?["name"] as? String else { return }
            titleName = name
        }
        // 语音识别结果实时写进输入框（不自动发送，让用户确认/编辑）
        .onChange(of: speech.transcript) { text in
            if !text.isEmpty { input = text }
        }
        .onAppear { reloadPersonaConfig() }
        .task {
            titleName = persona.name
            #if DEBUG
            if demo {
                msgs = [
                    Msg(role: "user", content: "在吗"),
                    Msg(role: "assistant", content: "（她抬眼看你）在的，刚泡了杯茶。今天想聊点什么？"),
                    Msg(role: "user", content: "随便聊聊，今天有点累"),
                    Msg(role: "assistant", content: "那就别硬撑了。（把椅子往你这边挪了挪）先说说，是身体累还是心里累？")
                ]
            } else {
                msgs = LocalStore.load(pid: persona.id)
            }
            #else
            msgs = LocalStore.load(pid: persona.id)
            #endif
            reloadPersonaConfig()
        }
    }

    // MARK: - 每角色配置读取

    /// 从 UserDefaults 读该角色选的模型与温度（角色设置页保存后返回会重新触发）。
    @MainActor
    private func reloadPersonaConfig() {
        selectedModelID = UserDefaults.standard.string(forKey: modelKey) ?? ""
        // 温度：没存过用 1.0（object 判空，避免把 0 当成未设置）
        if let t = UserDefaults.standard.object(forKey: tempKey) as? Double {
            temperature = t
        } else {
            temperature = 1.0
        }
        // 拉一次模型默认值（公开接口，失败就用 deepseek-flash 兜底，不阻塞聊天）
        Task {
            if let list = try? await APIClient.llmModels() {
                await MainActor.run { modelDefaultID = list.defaultID }
            }
        }
    }

    // MARK: - 表情包面板（2.9：读广场数据，点表情直接插到聊天）

    @ViewBuilder
    private var stickerSheet: some View {
        ZStack {
            GlassBackdrop()
            VStack(spacing: 10) {
                HStack {
                    Text("表情包")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                    Spacer()
                    Button("完成") { showStickerSheet = false }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
                .padding(.horizontal, 20).padding(.top, 14)

                if stickerLoading && stickerPacks.isEmpty {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text("正在读取表情包…").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                    Spacer()
                } else if stickerPacks.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 34))
                            .foregroundStyle(AE.textSecondary)
                        Text("还没有下载的表情包")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(AE.textPrimary)
                        Text("表情包来自人设广场，下载后就能在这里发。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AE.textSecondary)
                        Button { openStickerPlaza() } label: {
                            Text("去人设广场的表情包 tab 下载")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).frame(height: 36)
                                .background(AE.accentDeep, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(stickerPacks) { pack in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 6) {
                                        CachedRemoteImage(
                                            url: APIClient.mediaURL(pack.cover),
                                            scope: "pack:\(pack.id)"
                                        ) {
                                            RoundedRectangle(cornerRadius: 6).fill(AE.accentSoft)
                                        }
                                        .frame(width: 24, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        Text(pack.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(AE.textPrimary)
                                        Spacer(minLength: 0)
                                    }
                                    LazyVGrid(
                                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5),
                                        spacing: 8
                                    ) {
                                        ForEach(Array(pack.items.enumerated()), id: \.offset) { pair in
                                            Button { sendSticker(pair.element) } label: {
                                                CachedRemoteImage(
                                                    url: APIClient.mediaURL(pair.element),
                                                    scope: "pack:\(pack.id):\(pair.offset)"
                                                ) {
                                                    RoundedRectangle(cornerRadius: 10).fill(AE.accentSoft)
                                                }
                                                .frame(height: 54)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            }
                                            .buttonStyle(AevisPressStyle(scale: 0.94))
                                            .accessibilityLabel("发送表情")
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                    }
                }

                if !stickerTip.isEmpty {
                    Text(stickerTip)
                        .font(.system(size: 11))
                        .foregroundStyle(AE.textSecondary)
                        .padding(.horizontal, 20)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .glassSheetBackground()
        .task { await loadStickerPacks() }
    }

    /// 广场表情包：先读硬缓存（预加载已落盘），再拿服务端最新结果覆盖；失败留旧值。
    private func loadStickerPacks() async {
        await MainActor.run { stickerLoading = true }
        var packs = APIClient.cachedJSON(.emojiPacks)
            .map(APIClient.parseEmojiPacks) ?? []
        if let fresh = try? await APIClient.emojiPacks(token: session.token) { packs = fresh }
        await MainActor.run {
            stickerPacks = packs
            stickerLoading = false
        }
    }

    /// 没有下载包时给一个明确入口，而不是空壳。用通知让主页切到广场表情包 tab。
    private func openStickerPlaza() {
        showStickerSheet = false
        NotificationCenter.default.post(
            name: CharacterSettingsView.openStickerPlaza,
            object: nil
        )
    }

    /// 点表情 → 作为一条图片消息落盘并出现在聊天里。
    /// 后端 SSE 目前只收文本，所以这是本地插入并说明；不假装已发到云端。
    @MainActor
    private func sendSticker(_ raw: String) {
        guard let url = APIClient.mediaURL(raw) else {
            stickerTip = "这个表情没有可用地址，暂时发不了"
            return
        }
        var m = Msg(role: "user", content: "[表情]")
        m.img = url.absoluteString
        msgs.append(m)
        LocalStore.save(pid: persona.id, msgs: msgs)
        showStickerSheet = false
        atBottom = true
    }

    @ViewBuilder
    private func row(_ m: Msg) -> some View {
        let mine = m.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if !mine && avatarMode != 2 {
                // 对方头像：空串/相对路径统一走 personaAvatarURL（空 → 占位）
                avatar(personaAvatarURL, name: persona.name)
            }
            if mine { Spacer(minLength: 40) }

            if !m.img.isEmpty, let imgURL = URL(string: m.img) {
                // 表情包图片消息：走同一套硬缓存；没有缓存时显示占位，不转圈。
                CachedRemoteImage(url: imgURL, scope: "sticker:\(m.id.uuidString)") {
                    ZStack {
                        AE.accentSoft
                        Image(systemName: "face.smiling").foregroundStyle(AE.textSecondary)
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: AEGlass.bubbleRadius, style: .continuous))
                .background(RoundedRectangle(cornerRadius: AEGlass.bubbleRadius, style: .continuous)
                    .fill(bubbleFill(mine: mine)))
            } else {
                Text(annotated(m.content))
                    .font(.system(size: fontSize))
                    .lineSpacing(fontSize * 0.45)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    // 气泡（2026-11-25 二次校准，按用户参考图定妆）：
                    // 底 white.opacity(0.70)（暗色 0.62 深灰），圆角 20 连续圆角，**无描边**。
                    // 参考图的气泡上没有高光框 —— 之前那圈白描边撤掉了（`AEGlass.strokeOpacity` 统一控制）。
                    .background(RoundedRectangle(cornerRadius: AEGlass.bubbleRadius, style: .continuous)
                        .fill(bubbleFill(mine: mine)))
                    .clipShape(RoundedRectangle(cornerRadius: AEGlass.bubbleRadius, style: .continuous))
            }

            if !mine { Spacer(minLength: 40) }
            if mine && avatarMode == 0 {
                // 「我」的头像从当前登录用户取（Session.avatar），空则用矢量感占位
                avatar(myAvatarURL, name: "我")
            }
        }
        .padding(.horizontal, 12)
    }

    /// 气泡底色：半透明，让全屏背景透上来（数值见 `AEGlass`，参考图定妆 0.70 / 0.62）。
    /// - 我：浅色偏白 + 一点点品牌靛蓝（可辨识但不刺眼）；深色用深靛蓝半透。
    /// - 对方：中性半透白 / 深灰。
    /// 两边都不超过 0.72 不透明度 —— 再高就变成实心板，背景等于没了。
    private func bubbleFill(mine: Bool) -> Color {
        if mine {
            return Color.adaptive(
                dark: Color.hex(0x2E3A57).opacity(0.68),
                light: Color.white.opacity(AEGlass.bubbleFillOpacity)
            )
        }
        return Color.adaptive(
            dark: Color.hex(0x232630).opacity(AEGlass.bubbleDarkFillOpacity),
            light: Color.white.opacity(AEGlass.bubbleFillOpacity)
        )
    }

    // MARK: - 底部悬浮区（2026-11-25）

    /// 生产环境只认 `momentPrompt`；CI 的 `-demo` 截图给一份样例，
    /// 这样版式能在打包前被真实截图验证，又不会在线上编造「对方发了动态」。
    private var activeMomentPrompt: String? {
        if let moment = momentPrompt, !moment.isEmpty { return moment }
        #if DEBUG
        return demo ? "对方发了一条动态" : nil
        #else
        return nil
        #endif
    }

    /// 悬浮胶囊「对方发了一条动态　查看」。
    /// 参考图：`white.opacity(0.75)`、全圆角；「查看」用强调色 semibold，其余常规字重。
    private func momentPill(_ text: String) -> some View {
        Button {
            onOpenMoment?()
        } label: {
            HStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)
                Text("查看")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.accent)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule().fill(Color.adaptive(
                    dark: Color.hex(0x2A2D36).opacity(0.75),
                    light: Color.white.opacity(0.75)
                ))
            )
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel("\(text)，查看")
    }

    /// 输入栏右侧的麦克风：按住说话（微信式），上滑 60pt 取消。
    /// `minimumDistance: 0` = 按下即触发。
    private var micGlyph: some View {
        Image(systemName: speech.recording ? "mic.fill" : "mic")
            .font(.system(size: 20))
            .foregroundStyle(micPressed ? (cancelZone ? AE.textSecondary : .red) : AE.accent)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !micPressed {
                            micPressed = true
                            speech.baseText = input     // 保留输入框已有内容
                            speech.start()
                        }
                        cancelZone = v.translation.height < -60
                    }
                    .onEnded { _ in
                        micPressed = false
                        if cancelZone { speech.cancel() } else { speech.finish() }
                        cancelZone = false
                    }
            )
            .accessibilityLabel("按住说话")
    }

    /// 括号内容变浅：`（…）` / `(…)` 用 60% 前景色（跟安卓同一套）。
    private func annotated(_ text: String) -> AttributedString {
        var out = AttributedString()
        var depth = 0
        for ch in text {
            if ch == "（" || ch == "(" { depth += 1 }
            var piece = AttributedString(String(ch))
            if depth > 0 && annotDim {
                piece.foregroundColor = .secondary.opacity(0.6)
            }
            if ch == "）" || ch == ")" { depth = max(0, depth - 1) }
            out.append(piece)
        }
        return out
    }

    // MARK: - 错误条动作

    private var errorIcon: String {
        switch errorKind {
        case .relogin: return "person.crop.circle.badge.exclamationmark"
        case .recharge: return "creditcard.trianglebadge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch errorKind {
        case .relogin:
            Button("重新登录") { session.signOut() }
                .font(.caption).buttonStyle(.borderedProminent)
        case .recharge:
            // 去充值引导：额度不足时给重发不解决问题，主按钮仍是「重发」让用户补足后重试。
            // 商城入口在主页（MainTabView 全屏），此处不跨模块跳转，避免与其它 worker 冲突。
            Button("重发") { Task { await resend() } }
                .font(.caption).buttonStyle(.borderedProminent)
                .disabled(sending)
        case .retry, .none:
            Button("重发") { Task { await resend() } }
                .font(.caption).buttonStyle(.bordered)
                .disabled(sending)
        }
    }

    /// 头像：硬缓存（磁盘 + 条件请求 304），AsyncImage 会每次重新下载且断网就没了。
    /// 空URL直接出占位（渐变圆底 + 首字）。
    @ViewBuilder
    private func avatar(_ url: URL?, name: String) -> some View {
        if let url {
            CachedRemoteImage(url: url, scope: "persona:\(persona.id)") {
                avatarPlaceholder(name)
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
        } else {
            avatarPlaceholder(name)
        }
    }

    /// 矢量感头像占位：深墨靛蓝渐变圆底 + 首字，和 ChatListView 的占位同一套视觉。
    @ViewBuilder
    private func avatarPlaceholder(_ name: String) -> some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [AE.accentLift, AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(String(name.prefix(1)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
        .shadow(color: AE.shadowColor, radius: 2, y: 1)
    }

    /// 对方头像 URL：空 → nil（走占位）；相对路径拼当前线路 base；拼完非法也回落 nil。
    private var personaAvatarURL: URL? {
        let s = persona.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        // 相对路径（/xxx 或 xxx）：拼当前线路 base
        let joined = s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s
        return URL(string: joined)
    }

    /// 「我」的头像 URL：Session.avatar（登录/冷启动时从 /v1/me 取），空 → nil 占位。
    private var myAvatarURL: URL? {
        let s = session.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        let joined = s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s
        return URL(string: joined)
    }

    private func abs(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("http") { return path }
        if path.hasPrefix("/") { return APIClient.base + path }
        return APIClient.base + "/" + path
    }

    /// 输入框发送。
    /// ⚠️ 旧版这里 `guard session.token != nil else { return }` 静默返回，用户看到
    /// "点发送没反应"。现在：token 缺失 → 明确提示「登录已过期」+ 重新登录入口。
    @MainActor
    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard session.token != nil else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        input = ""
        atBottom = true                     // 用户主动发送 → 允许回到底部跟随
        await performSend(text: text, allowLineRetry: true)
    }

    /// 失败后重发：删掉最后一条 user 及其后的回复，把那条 user 的原文重新送一遍。
    @MainActor
    private func resend() async {
        guard session.token != nil else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        guard let lastUser = msgs.last(where: { $0.role == "user" }) else { return }
        let text = lastUser.content
        if let idx = msgs.lastIndex(where: { $0.role == "user" }) {
            msgs = Array(msgs.prefix(upTo: idx))
        }
        LocalStore.save(pid: persona.id, msgs: msgs)
        await performSend(text: text, allowLineRetry: true)
    }

    /// 发送一段文本：落盘用户消息 → SSE 逐字收增量 → 落盘完整回复。
    /// 线路回落（直连→北京）已内置在 `APIClient.sendChatStream` 里，
    /// 这里不再做二次换线重试（否则已出字时会重复内容）。`allowLineRetry` 仅为兼容旧调用保留。
    @MainActor
    private func performSend(text: String, allowLineRetry: Bool = true) async {
        guard let token = session.token else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        var mine = Msg(role: "user", content: text)
        mine.id = UUID()
        msgs.append(mine)
        LocalStore.save(pid: persona.id, msgs: msgs)

        #if DEBUG
        if demo {
            // 截图模式：假的延时回一句，保持非流式（CI 截图靠它）
            sending = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            msgs.append(Msg(role: "assistant", content: "（她笑了笑）我在听。"))
            LocalStore.save(pid: persona.id, msgs: msgs)
            sending = false
            return
        }
        #endif

        // 先插一条空 assistant，后续每个 delta 按 id 增量拼到它上面（不是替换）
        let assistantID = UUID()
        var placeholder = Msg(role: "assistant", content: "")
        placeholder.id = assistantID
        msgs.append(placeholder)

        sending = true
        error = ""
        errorKind = .none
        // 只带最近 20 条；dropLast 去掉刚插入的空 assistant，别把空内容发给模型
        let payload = msgs.dropLast().suffix(20).map { ["role": $0.role, "content": $0.content] }

        do {
            let full = try await streamReply(token: token, assistantID: assistantID, payload: payload)
            // 收尾：用完整文本校准（防止增量回调排队丢帧），落盘 + 触发云备份
            await MainActor.run {
                if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
                    msgs[i].content = full
                    scrollTick += 1
                }
                LocalStore.save(pid: persona.id, msgs: msgs)
                CloudBackup.shared.pushIfNeeded(token: token)
            }
        } catch {
            // 线路回落已由 APIClient.sendChatStream 内部完成（直连→北京）。
            // 这里不再二次换线重试 —— 否则已吐字的情况下会重复拼内容。
            // 只需：把最终失败归类成可见错误 + 处理空气泡（可点「重发」）。
            await reportFailure(error, assistantID: assistantID)
        }
        sending = false
    }

    /// 发一轮 SSE 流式请求（抽出来供「首次 + 线路重试」两处复用）。
    /// model 用**该角色**选中的模型（modelForPersona）；temperature 用该角色温度设置。
    private func streamReply(
        token: String, assistantID: UUID, payload: [[String: String]]
    ) async throws -> String {
        try await APIClient.sendChatStream(
            token: token, model: modelForPersona, messages: payload,
            temperature: temperature,
            onDelta: { delta in
                // onDelta 在 URLSession 后台线程回调，切回主线程改 @State 并触发滚动
                DispatchQueue.main.async {
                    guard let i = msgs.firstIndex(where: { $0.id == assistantID }) else { return }
                    msgs[i].content += delta
                    scrollTick += 1
                }
            }
        )
    }

    /// 归类错误并撤/标记空气泡。SSE 是流式，错误里可能已经出了部分字符，保留并提示重发。
    @MainActor
    private func reportFailure(_ error: Error, assistantID: UUID) {
        let (msg, kind) = Self.classify(error)
        withAnimation {
            self.error = msg
            self.errorKind = kind
        }
        if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
            if msgs[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                msgs.remove(at: i)          // 一个字都没出：撤掉空气泡，可点「重发」
            } else {
                msgs[i].content += "\n（回复中断，可点「重发」）"
                LocalStore.save(pid: persona.id, msgs: msgs)
            }
        }
    }

    /// 错误 → (人话提示, 动作类型)。覆盖：401/403 掉签、402/额度不足、SSL/网络、其它。
    static func classify(_ error: Error) -> (String, ErrorKind) {
        if let api = error as? APIError {
            switch api {
            case let .http(code, msg):
                if code == 401 || code == 403 {
                    return ("登录已过期，请重新登录。", .relogin)
                }
                if code == 402 || code == 4020 || code == 4021 || code == 4022 {
                    return ("本周额度已用完，请充值墨点或开通会员。", .recharge)
                }
                let m = msg.isEmpty ? "请求失败（\(code)）" : msg
                return (m, .retry)
            case let .decode(m):
                return ("数据解析失败：\(m)", .retry)
            }
        }
        // URLError：SSL 失败（自签证书不在 ATS 例外内 / 证书链问题）、断网、超时
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorServerCertificateUntrusted,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected:
                return ("线路证书校验失败，已尝试切换线路，请重试。", .retry)
            case NSURLErrorNotConnectedToInternet:
                return ("网络未连接，请检查网络后重试。", .retry)
            case NSURLErrorTimedOut:
                return ("连接超时，请重试。", .retry)
            default:
                return (error.localizedDescription, .retry)
            }
        }
        return (error.localizedDescription, .retry)
    }

    /// 是否「线路级」错误（值得换一条线路重试）：SSL 失败 / 连不上 / 超时 / 5xx。
    static func isLineLevelError(_ error: Error) -> Bool {
        if let api = error as? APIError, case let .http(code, _) = api {
            return code == 0 || (500...599).contains(code)
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost:
            return true
        default:
            return false
        }
    }
}

/// 底部哨兵的位置偏好键（判断「是否贴底」用）。
private struct BottomEdgeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 本地语音输入（ASR，2026-11-24）。替代原来的 TTS。
///
/// 流程（微信式「按住说话」）：
///   按下麦克风 → 请求麦克风+语音识别权限 → 起 AVAudioEngine 录音 + 实时识别，
///   partial 结果经 `transcript` 冒给界面写进输入框；松手 `finish()` 结束并保留最终文字；
///   上滑 `cancel()` 丢弃。
///
/// 防崩要点（最常见的内存/崩溃点，逐条处理）：
///   · 每次开始前先 `engine.stop()` + `removeTap` + `request.endAudio()`，绝不复用旧 tap/request；
///   · `removeTap` 只在确实装过 tap 时调（没装还调会抛 NSException，Swift 抓不住）；
///   · 结束时严格顺序：stop engine → removeTap → endAudio → 会话失活；
///   · 识别结束（isFinal）后把 `task`/`request` 置 nil，不复用。
final class SpeechInput: ObservableObject {
    @Published var transcript = ""      // 实时识别文本（base + partial）
    @Published var recording = false    // 是否正在录音
    @Published var hint = ""            // 顶部提示（录音中 / 不可用原因）

    /// 录音开始前输入框里已有的文字，识别结果拼在它后面。
    var baseText = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    /// 松手早于权限返回时的「待停」标记：权限一通过就立刻收尾，避免卡在录音态。
    private var stopRequested = false

    // MARK: - 权限

    /// 先语音识别、再麦克风，都通过才算可用。全部主线程回调。
    private func ensurePermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { done(false); return }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async { done(granted) }
                }
            }
        }
    }

    // MARK: - 开始 / 结束 / 取消

    func start() {
        stopRequested = false
        hint = ""
        guard let recognizer, recognizer.isAvailable else {
            hint = "语音输入不可用"
            return
        }
        ensurePermission { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.hint = "语音输入不可用（未授权麦克风或语音识别）"
                return
            }
            // 权限弹窗期间用户已松手 → 直接收尾，别起录音
            if self.stopRequested { self.stopRequested = false; return }
            do {
                try self.beginSession()
            } catch {
                self.hint = "语音输入不可用"
                self.teardown()
            }
        }
    }

    private func beginSession() throws {
        // 先彻底清干净上一次（含 task/request 置 nil），避免复用崩溃
        teardown()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let node = engine.inputNode
        let fmt = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcript = self.baseText + text
                    // 识别结束：彻底清理 task/request（用户要的「别复用」）。
                    // 在自己的回调里只置 nil、不 cancel 自己。
                    if result.isFinal { self.teardown(cancelTask: false) }
                }
                if error != nil {
                    // 识别出错：若还在录音就彻底收尾；已有部分结果则保留，别把用户说的吞掉
                    if self.recording { self.teardown(cancelTask: false) }
                }
            }
        }
        recording = true
        hint = "松开结束，上滑取消"
    }

    /// 松手：结束录音、保留最终文字（不自动发送）。
    func finish() {
        if !recording { stopRequested = true; return }   // 还没真正开始（权限未回），标记待停
        finishInternal()
    }

    /// 上滑取消：丢弃这段识别，还原到录音前的输入。
    func cancel() {
        stopRequested = true
        if recording {
            task?.cancel()
            transcript = baseText
            finishInternal(cancelled: true)
        }
        hint = ""
    }

    /// 停止引擎 + 摘 tap + endAudio + 会话失活；`task` 交给自然收尾或取消。
    private func finishInternal(cancelled: Bool = false) {
        teardownEngineOnly()
        recording = false
        hint = ""
        if cancelled {
            task?.cancel()
            task = nil
            request = nil
        }
        // 非取消：等 recognitionTask 的 isFinal 回调里再彻底置 nil（见下）
    }

    /// 只停录音链路，不动 task/request 的收尾（开始前 & 结束时都用）。
    private func teardownEngineOnly() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: .notifyOthersOnDeactivation)
        } catch { /* 忽略：失活失败不影响下次 */ }
    }

    /// 彻底清理。`cancelTask=false` 用于「isFinal 回调里」——不要在识别任务自己的
    /// 回调栈里 cancel 自己（只是置 nil 让它自然结束即可）。
    private func teardown(cancelTask: Bool = true) {
        teardownEngineOnly()
        if cancelTask { task?.cancel() }
        task = nil
        request = nil
        tapInstalled = false
        recording = false
        hint = ""
    }
}
