import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatStore

    /// 用来在用户换字体/调字号时重新渲染。
    @ObservedObject private var fonts = FontStore.shared

    /// 快捷指令送来的信号（要问的话、要弹的界面）在这里等着被取走。
    @ObservedObject private var bridge = BridgeInbox.shared

    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var toolNote: String?
    @State private var showSettings = false
    @State private var showMoments = false
    @State private var showTogether = false
    @State private var showCall = false
    @State private var sendTask: Task<Void, Never>?
    @State private var didLaunchTest = false

    // 附件：拍照 / 选图 / 选文件 → OCR → 塞进输入框
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var attaching = false
    @FocusState private var composerFocused: Bool

    private var persona: Persona { personaStore.persona }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 她在动手的时候，这里会变成「她看了眼时间…」，比干等一个「正在输入」有信息量。
    private var statusText: String {
        if let toolNote { return toolNote + "…" }
        return isSending ? "正在输入…" : "在线"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                composer
                bottomBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
        .sheet(isPresented: $showMoments) {
            MomentsView()
        }
        .sheet(isPresented: $showTogether) {
            TogetherView()
        }
        .fullScreenCover(isPresented: $showCall) {
            CallView()
        }
        .onDisappear {
            sendTask?.cancel()
        }
        .onAppear {
            // 只在 CI 截图自检时用：带这个参数启动就直接把设置面板打开。
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenSettings") {
                showSettings = true
            }
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenMoments") {
                showMoments = true
            }
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenTogether") {
                showTogether = true
            }
            #endif
            drainBridgeInbox()
            // 录屏扩展在另一个进程里攒着文字，进聊天页先拉一次 ——
            // 这样你刚看完抖音回来问她，她就已经知道了。
            ScreenCompanion.shared.refreshFromExtension()
            runLaunchTestIfNeeded()
        }
        // 快捷指令可能是在 App 已经开着的时候发回来 —— 那就靠变化来触发。
        .onChange(of: bridge.ask) { _, _ in drainBridgeInbox() }
        .onChange(of: bridge.openCall) { _, _ in drainBridgeInbox() }
        .onChange(of: bridge.openListen) { _, _ in drainBridgeInbox() }
        .onChange(of: pickedPhotos) { _, items in
            handlePickedPhotos(items)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: attachmentTypes,
            allowsMultipleSelection: false
        ) { result in
            handlePickedFile(result)
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                attach(from: image, source: "照片")
            }
            .ignoresSafeArea()
        }
        #endif
    }

    // MARK: - 附件
    //
    // 取出的文字**直接放进输入框**，不是偷偷发出去。
    // 用户能在后面接着写"帮我总结一下"，发出去的是「内容 + 指令」——
    // 她收到的是一段能读的文字，不是一张她看不见的图。

    private var attachmentTypes: [UTType] {
        AttachmentService.allowedFileTypes.compactMap { UTType(filenameExtension: $0) }
    }

    private func handlePickedPhotos(_ items: [PhotosPickerItem]) {
        guard let item = items.first else { return }
        pickedPhotos = []
        Task { @MainActor in
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorText = "这张图读不出来，换一张试试。"
                return
            }
            attach(from: image, source: "图片")
        }
    }

    private func attach(from image: UIImage, source: String) {
        attaching = true
        Task { @MainActor in
            defer { attaching = false }
            let text = await AttachmentService.recognizeText(in: image)
            guard !text.isEmpty else {
                errorText = "这张图里没认出文字。拍清楚一点，或者换一张。"
                return
            }
            draft = AttachmentService.composerBlock(text, source: source) + draft
            errorText = nil
        }
    }

    private func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if let text = AttachmentService.readTextFile(at: url) {
                draft = AttachmentService.composerBlock(text, source: url.lastPathComponent) + draft
                errorText = nil
            } else {
                errorText = "这个文件我读不了文字。现在只支持纯文本类：txt / md / csv / json / log 这些。"
            }
        case .failure(let error):
            errorText = "选文件失败：\(error.localizedDescription)"
        }
    }

    /// 启动时自动测一次连接。不通就直接说出来 ——
    /// 免得用户对着一句没反应的对话框猜是哪里坏了。
    private func runLaunchTestIfNeeded() {
        guard !didLaunchTest else { return }
        didLaunchTest = true
        guard settings.autoTestOnLaunch, settings.isConfigured else { return }

        let config = settings.llm
        Task { @MainActor in
            do {
                _ = try await LLMService.probe(config: config)
            } catch {
                errorText = "启动自检没连上：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 顶部
    //
    // 和底部输入栏**用同一种材质** —— 之前上面是渐隐模糊、下面是实底，
    // 两条颜色不一样，看着别扭（用户说的「上面颜色统一一下」）。

    private var header: some View {
        HStack(spacing: 11) {
            AevisAvatar(size: settings.simpleMode ? 40 : 36, seed: persona.avatarSeed)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.name)
                    .font(.aevis(settings.simpleMode ? 18 : 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(statusText)
                    .font(.aevis(settings.simpleMode ? 13 : 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                composerFocused = false
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .aevisGlass(cornerRadius: 20)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        // 和底部那条同一种材质，颜色统一
        .background(Rectangle().fill(.bar).ignoresSafeArea(edges: .top))
    }

    // MARK: - 消息列表
    //
    // 气泡外观在这里取一份快照传下去 —— 气泡自己是纯渲染，
    // 不受观察机制影响，也就不会出现「改了设置这边不跟着变」。

    private var bubbleTheme: BubbleTheme {
        BubbleTheme(
            myLook: settings.myBubble,
            aiLook: settings.aiBubble,
            myColor: settings.bubbleColor(settings.myBubble),
            aiColor: settings.bubbleColor(settings.aiBubble),
            cornerScale: settings.cornerScale,
            fontColor: settings.fontColor,
            showMyAvatar: settings.showMyAvatar,
            showAiAvatar: settings.showAiAvatar
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: settings.simpleMode ? 16 : 12) {
                    if chat.messages.isEmpty {
                        emptyState
                    }

                    ForEach(chat.messages) { message in
                        MessageBubble(
                            message: message,
                            persona: persona,
                            theme: bubbleTheme,
                            simpleMode: settings.simpleMode
                        )
                        .id(message.id)
                    }

                    if let errorText {
                        noticeBubble(errorText)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            // 手指一拖就收
            .scrollDismissesKeyboard(.immediately)
            // 点消息区任意位置也能收
            .onTapGesture {
                composerFocused = false
            }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: errorText) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            AevisOrb()
                .scaleEffect(0.72)
            Text("\(persona.pronoun)在这儿。")
                .font(.aevis(settings.simpleMode ? 19 : 17, weight: .medium))
                .foregroundStyle(.primary)
            if settings.isConfigured {
                Text("说点什么开始吧。TA 能看时间、翻日历、记提醒、算数、读写剪贴板。")
                    .font(.aevis(settings.simpleMode ? 15 : 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                Text("还差一步：右上角设置 →「模型接入」，填上你的 API Key，TA 才会说话。")
                    .font(.aevis(settings.simpleMode ? 15 : 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 30)
        .padding(.bottom, 16)
    }

    private func noticeBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .aevisGlass(cornerRadius: 14)
            Spacer(minLength: 30)
        }
    }

    // MARK: - 底部输入栏
    //
    // 三处修正（都是用户实测发现的）：
    // 1. 玻璃要整条加在容器上，不能加在 TextField 上（自带样式的控件不生效）
    // 2. 底下垫一条实底，消息不会从输入栏周围透上来
    // 3. 「收起」放在输入栏同一排，不再飘在键盘上方

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // 附件：选图（走相册）和拍照/选文件（走菜单）
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 3, matching: .images) {
                Image(systemName: attaching ? "hourglass" : "photo.on.rectangle")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(attaching)
            .padding(.bottom, 5)
            .padding(.leading, 3)

            Menu {
                #if canImport(UIKit)
                if AttachmentService.cameraAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("拍张照", systemImage: "camera")
                    }
                }
                #endif
                Button {
                    showFileImporter = true
                } label: {
                    Label("选一个文件", systemImage: "doc.text")
                }
            } label: {
                Image(systemName: "paperclip")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 30)
                    .contentShape(Rectangle())
            }
            .disabled(attaching)
            .padding(.bottom, 5)

            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.aevis(settings.simpleMode ? 17 : 15))
                .focused($composerFocused)
                .disabled(isSending)
                .padding(.vertical, settings.simpleMode ? 10 : 8)
                .padding(.leading, 12)
                .padding(.trailing, 2)

            if composerFocused {
                Button {
                    composerFocused = false
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            Button(action: send) {
                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.aevis(settings.simpleMode ? 16 : 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: settings.simpleMode ? 38 : 34, height: settings.simpleMode ? 38 : 34)
                    .background(
                        Circle().fill(
                            isSending ? Color.gray.opacity(0.55)
                            : (canSend ? settings.accentColor : Color.gray.opacity(0.35))
                        )
                    )
                    .contentShape(Circle())
            }
            .disabled(!canSend && !isSending)
            .padding(.bottom, 1)
        }
        .padding(6)
        .aevisGlass(cornerRadius: 26)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
        // 和顶栏、底部功能栏同一种材质，颜色统一
        .background(Rectangle().fill(.bar))
    }

    // MARK: - 底部功能栏（微信那样的一排）
    //
    // 用户要求：朋友圈这些入口别藏在右上角三个点里，要像微信那样摆在底下一排。
    //
    // 顺便修掉那个「输入框下面有一条白」：那条是**背景没铺到屏幕最下沿**导致的 ——
    // 这里给功能栏的背景加 `ignoresSafeArea(edges: .bottom)`，
    // 一直铺到屏幕底边，就不再留白了。

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barItem("朋友圈", "photo.on.rectangle.angled") {
                composerFocused = false
                showMoments = true
            }
            barItem("一起听", "music.note.list") {
                composerFocused = false
                showTogether = true
            }
            barItem("通话", "phone.arrow.up.right") {
                composerFocused = false
                showCall = true
            }
            barItem("设置", "slider.horizontal.3") {
                composerFocused = false
                showSettings = true
            }
        }
        .padding(.top, 7)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.bar)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func barItem(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.aevis(17, weight: .medium))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.aevis(10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var placeholder: String {
        persona.name.isEmpty ? "说点什么…" : "和 \(persona.name) 说点什么…"
    }

    // MARK: - 快捷指令送来的信号

    /// 快捷指令「打开 URL」之后，App 可能是**刚被拉起来的**（那时聊天页还没出现），
    /// 也可能本来就开着。所以 onAppear 和值变化时都看一眼 —— 谁先到都不会漏。
    private func drainBridgeInbox() {
        if let text = bridge.ask,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            bridge.ask = nil
            draft = text
            send()
        }
        if bridge.openCall {
            bridge.openCall = false
            showCall = true
        }
        if bridge.openListen {
            bridge.openListen = false
            showTogether = true
        }
    }

    // MARK: - 发送

    private func send() {
        if isSending {
            sendTask?.cancel()
            sendTask = nil
            isSending = false
            toolNote = nil
            chat.removeLastIfEmpty()
            SpeechService.shared.stop()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        errorText = nil
        toolNote = nil
        SpeechService.shared.stop()

        chat.append(ChatMessage(role: .user, text: text))
        chat.append(ChatMessage(role: .assistant, text: ""))

        let config = settings.llm
        let prompt = persona.systemPrompt
        let history = chat.messages.filter { !($0.role == .assistant && $0.text.isEmpty) }
        // 背景资料 = 长期记忆 +（快捷指令发过数据的话）屏幕使用时间 + 外面来的信息
        var context = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        let screenTime = ScreenTimeInsight.shared.digest()
        if !screenTime.isEmpty { context.append(screenTime) }
        // 位置 / 电量 / 步数 / 天气这些是**用户主动用快捷指令喂进来的**，
        // 跟「长期记忆」不是一回事，所以不受上面那个开关影响。
        context.append(contentsOf: AmbientContext.shared.digest())
        let remember = settings.memoryEnabled
        let shouldSpeak = settings.speakerEnabled
        let ttsConfig = settings.tts
        let systemVoice = persona.voiceIdentifier

        isSending = true
        sendTask = Task { @MainActor in
            // accumulated = 整段（念出来、提炼记忆都用它）
            // pending     = 还没定稿的这一条
            var accumulated = ""
            var pending = ""

            /// 她换行就等于换一条消息 —— 这样看起来才是一条一条发出来的。
            ///
            /// ⚠️ 这里**绝对不能**在流结束时再「强制定稿一次」。
            /// 踩过的坑：`pending` 一直是靠 `replaceLast` 实时显示在最后一条上的，
            /// 结束时再调一次 `finishStreamingLine(pending)`，它会发现最后一条已经
            /// 不是空的了，于是**又追加一条一模一样的内容** ——
            /// 表现就是她每句话都说两遍。
            func flushLines() {
                while let index = pending.firstIndex(of: "\n") {
                    let line = String(pending[pending.startIndex..<index])
                    pending.removeSubrange(pending.startIndex...index)
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    chat.finishStreamingLine(trimmed)
                }
                // 正在吐的这条实时显示在最后一条上
                if !pending.isEmpty {
                    chat.replaceLast(with: pending)
                }
            }

            do {
                for try await piece in LLMService.streamReply(
                    config: config,
                    systemPrompt: prompt,
                    history: history,
                    memory: context,
                    tools: DeviceTools.all(),
                    onToolActivity: { title in
                        Task { @MainActor in
                            toolNote = title
                        }
                    }
                ) {
                    // 她开始说话了，把「她看了眼时间…」收掉
                    if toolNote != nil { toolNote = nil }
                    accumulated += piece
                    pending += piece
                    flushLines()
                }
                // 收尾：剩下的 pending 早就显示在最后一条上了，这里只要清掉
                // 多余的空占位就行 —— **不要再定稿一次**（见上面那段注释）。
                chat.removeLastIfEmpty()
                chat.commit()
            } catch {
                chat.removeLastIfEmpty()
                if (error as? CancellationError) == nil {
                    errorText = error.localizedDescription
                }
            }

            isSending = false
            toolNote = nil
            sendTask = nil

            // 聊够了就顺手提炼一次长期记忆。
            // 放在回复之后 —— 不挡着说话，失败也只进记忆库的状态行。
            if remember {
                await MemoryStore.shared.extractIfNeeded(
                    config: config,
                    messages: chat.messages,
                    persona: persona
                )
            }

            if shouldSpeak, !accumulated.isEmpty {
                SpeechService.shared.speak(
                    accumulated,
                    config: ttsConfig,
                    systemVoiceIdentifier: systemVoice
                ) { message in
                    errorText = message
                }
            }
        }
    }
}

// MARK: - 气泡

/// 气泡外观的一份快照。父视图取好传下来，
/// 气泡本身只负责画 —— 这样两侧气泡能各改各的，互不影响。
struct BubbleTheme {
    var myLook: BubbleLook
    var aiLook: BubbleLook
    var myColor: Color
    var aiColor: Color
    var cornerScale: Double
    var fontColor: Color
    var showMyAvatar: Bool
    var showAiAvatar: Bool
}

private struct MessageBubble: View {
    let message: ChatMessage
    let persona: Persona
    var theme: BubbleTheme
    var simpleMode: Bool = false

    /// 订阅表情包 —— 判断这一条是不是"就是一个表情"要靠它。
    ///
    /// ⚠️ 必须声明在**这个** struct 里：`sticker` / `bigSticker` 都属于这里，
    /// 声明到外层的 ChatView 上，这里就找不到 `emoji` 了（真踩过，整轮编译失败）。
    @ObservedObject private var emoji = EmojiPack.shared

    /// 靠着屏幕那一边至少留这么多空白（也顺手限制了气泡宽度）。
    /// 用「单侧 Spacer 的 minLength」而不是写死像素宽度，这样任何屏幕尺寸都自适应。
    /// 两侧都留 54：一边是头像 26 + 间距 8 + 20，另一边对称。
    private static let sideGap: CGFloat = 54

    private var isUser: Bool { message.role == .user }

    private var look: BubbleLook { isUser ? theme.myLook : theme.aiLook }
    private var color: Color { isUser ? theme.myColor : theme.aiColor }

    private var bubbleFontSize: CGFloat { simpleMode ? 17.5 : 15.5 }
    private var horizontalPadding: CGFloat { simpleMode ? 16 : 14 }
    private var verticalPadding: CGFloat { simpleMode ? 13 : 10 }
    private var avatarSize: CGFloat { simpleMode ? 30 : 26 }

    /// 基础圆角再乘两层系数：全局的 + 这一侧自己的。
    private var bubbleCorner: CGFloat {
        let base: CGFloat = simpleMode ? 20 : 18
        let scaled = theme.cornerScale * look.cornerScale
        return max(6, base * CGFloat(scaled))
    }

    /// 整条消息就是一个表情 —— 像微信那样**放大显示**，不套气泡。
    ///
    /// 「一个表情」有两种写法：她自己写的 `[微笑]`，或者她直接发一个表情符号。
    /// 判断交给 EmojiPack —— 表情在设置里被关掉时，这里自然就都不算表情了。
    private var sticker: EmojiPack.Item? {
        emoji.single(in: message.text)
    }

    private func emojiText(_ item: EmojiPack.Item) -> some View {
        Text(item.emoji)
            .font(.aevis(simpleMode ? 56 : 48))
            .padding(.vertical, 2)
    }

    /// 大表情：**导入了自己的表情图就用图**（微信 / QQ 那套），没导就用表情符号。
    @ViewBuilder
    private func bigSticker(_ item: EmojiPack.Item) -> some View {
        #if canImport(UIKit)
        if let image = emoji.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: simpleMode ? 148 : 128, maxHeight: simpleMode ? 148 : 128)
                .padding(.vertical, 2)
        } else {
            emojiText(item)
        }
        #else
        emojiText(item)
        #endif
    }

    private var bubble: some View {
        Group {
            if let sticker {
                bigSticker(sticker)
            } else {
                AevisBubble(
                    text: message.text,
                    look: look,
                    color: color,
                    corner: bubbleCorner,
                    fontSize: bubbleFontSize,
                    horizontalPadding: horizontalPadding,
                    verticalPadding: verticalPadding,
                    plainTextColor: theme.fontColor
                )
            }
        }
    }

    var body: some View {
        if isUser {
            // 只放一个 Spacer。放两个的话剩余空白会被平分，气泡就飘到中间去了。
            HStack(alignment: .bottom, spacing: 8) {
                Spacer(minLength: Self.sideGap)
                bubble
                if theme.showMyAvatar {
                    AevisAvatar(source: .me, size: avatarSize)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if theme.showAiAvatar {
                    AevisAvatar(source: .ai, size: avatarSize, seed: persona.avatarSeed)
                }
                bubble
                Spacer(minLength: Self.sideGap)
            }
        }
    }
}
