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
    /// 底下那个「更多」面板（微信的加号）开没开。
    @State private var showMorePanel = false
    @State private var sendTask: Task<Void, Never>?
    @State private var didLaunchTest = false

    /// 设置 / 朋友圈 / 一起听 / 通话这几个面板提到了**根视图**上 ——
    /// 聊天页现在是二级页面，截图自检要在它还没出现时就打开那些面板。
    @ObservedObject private var router = AppRouter.shared

    /// 从会话列表点进来之后，靠它退回去。
    @Environment(\.dismiss) private var dismiss

    // 附件：拍照 / 选图 / 选文件 → OCR → 塞进输入框
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var attaching = false
    @State private var showScreenPanel = false
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
                // 微信那个加号下面的面板：点开才出来，收起就没了
                if showMorePanel {
                    morePanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                composer
            }
            // 面板和输入栏**共用**这一层背景，而且一直铺到屏幕最下沿 ——
            // 之前输入框下面留白，就是背景没铺到底。
            .background(
                Rectangle()
                    .fill(.bar)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
        // 顶栏是我们自己画的（微信那种：返回 + 头像 + 名字），
        // 所以把系统的导航栏藏掉，不然会顶着两个头。
        .toolbar(.hidden, for: .navigationBar)
        // 进了聊天就把底下那四个 tab 收掉 —— 微信也是这个行为，聊天页占满整屏。
        // 用户的原话：「我进入聊天了的话，下面那四个栏你就不用带上了。」
        .toolbar(.hidden, for: .tabBar)
        .onDisappear {
            sendTask?.cancel()
        }
        .onAppear {
            // 截图自检：把「更多」面板直接打开，否则截不到它。
            // （设置 / 朋友圈 / 一起听那几个开关搬到根视图了 ——
            //   它们要在聊天页还没出现的时候就能打开。）
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenMore") {
                showMorePanel = true
            }
            #endif
            drainBridgeInbox()
            // 录屏扩展在另一个进程里攒着文字，进聊天页先拉一次 ——
            // 这样你刚看完抖音回来问她，她就已经知道了。
            ScreenCompanion.shared.refreshFromExtension()
            runLaunchTestIfNeeded()
        }
        // 一开始打字就把「更多」面板收掉 —— 微信也是这个行为
        .onChange(of: composerFocused) { _, focused in
            if focused, showMorePanel {
                withAnimation(.snappy(duration: 0.22)) {
                    showMorePanel = false
                }
            }
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
        .sheet(isPresented: $showScreenPanel) {
            screenPanel
        }
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
            // 认字用原图（字大一点更容易认出来）；显示用的那份先压好。
            let picture = AttachmentService.compressed(image)
            let text = await AttachmentService.recognizeText(in: image)

            guard picture != nil || !text.isEmpty else {
                errorText = "这张图读不出来，换一张试试。"
                return
            }
            errorText = nil

            // 图留在聊天里显示，她拿到的是从图里认出来的文字。
            // 没认出字也要说一句 —— 不然她会以为收到了一张空图，转头胡猜。
            let block = text.isEmpty
                ? "（我发了一张图片，但里面没认出文字。）"
                : AttachmentService.composerBlock(text, source: source)
            send(text: block, image: picture)
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
                errorText = "这个文件我读不了文字。能读的是：PDF、Word（docx）、RTF，"
                    + "以及纯文本类（txt / md / csv / json / 代码）。"
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
            // 微信那样：最左边一个返回箭头（聊天页现在是二级页面了）
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
                router.showSettings = true
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
            showAiAvatar: settings.showAiAvatar,
            // 界面密度：只改留白，不改字号（字号是另一组开关）
            density: settings.densityScale
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: (settings.simpleMode ? 16 : 12) * CGFloat(settings.densityScale)) {
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

    /// 输入栏 —— 按微信那样：一个输入框，右边一个「更多」或发送。
    ///
    /// 用户要求：「聊天界面就跟微信一样，你别的东西就堆在那个"更多"里。」
    /// 所以相册、拍照、文件、朋友圈、一起听、通话、设置**全收进下面那个面板**，
    /// 输入栏这一排只留最必要的控件，不再铺一排按钮。
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.aevis(settings.simpleMode ? 17 : 15))
                .focused($composerFocused)
                .disabled(isSending)
                .padding(.vertical, settings.simpleMode ? 10 : 8)
                .padding(.horizontal, 12)

            if composerFocused {
                // 收键盘。微信里是点空白处，这里给个明确的按钮更省事。
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

            // 有字才出现发送 —— 微信也是这个规矩
            if canSend || isSending {
                Button(action: send) {
                    Image(systemName: isSending ? "stop.fill" : "arrow.up")
                        .font(.aevis(settings.simpleMode ? 16 : 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: settings.simpleMode ? 38 : 34,
                               height: settings.simpleMode ? 38 : 34)
                        .background(
                            Circle().fill(isSending ? Color.gray.opacity(0.55) : settings.accentColor)
                        )
                        .contentShape(Circle())
                }
                .padding(.bottom, 1)
            }

            // 「更多」—— 微信里那个加号
            Button {
                composerFocused = false
                withAnimation(.snappy(duration: 0.22)) {
                    showMorePanel.toggle()
                }
            } label: {
                Image(systemName: showMorePanel ? "xmark" : "plus")
                    .font(.aevis(16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: settings.simpleMode ? 38 : 34,
                           height: settings.simpleMode ? 38 : 34)
                    .aevisGlass(cornerRadius: settings.simpleMode ? 19 : 17)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 1)
        }
        .padding(6)
        .aevisGlass(cornerRadius: 26)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - 「更多」面板（微信那个加号下面的东西）
    //
    // 用户要求：「聊天界面就跟微信一样，你别的东西就堆在那个'更多'里。」
    // 所以原来铺在底下的那排按钮全撤了，改成点加号才展开的面板。
    //
    // 顺便保留那条修正：面板和输入栏**共用一个铺到屏幕最下沿的背景**
    // （在 body 里统一加），不然输入框下面会留一条白。

    private let moreColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var morePanel: some View {
        LazyVGrid(columns: moreColumns, spacing: 16) {
            PhotosPicker(selection: $pickedPhotos, maxSelectionCount: 3, matching: .images) {
                moreTile("相册", attaching ? "hourglass" : "photo.on.rectangle")
            }
            .disabled(attaching)

            #if canImport(UIKit)
            Button {
                showCamera = true
            } label: {
                moreTile("拍照", "camera")
            }
            .disabled(!AttachmentService.cameraAvailable)
            .opacity(AttachmentService.cameraAvailable ? 1 : 0.4)
            #endif

            Button {
                showFileImporter = true
            } label: {
                moreTile("文件", "doc.text")
            }

            Button {
                closeMorePanel()
                router.showMoments = true
            } label: {
                moreTile("朋友圈", "photo.on.rectangle.angled")
            }

            Button {
                closeMorePanel()
                router.showTogether = true
            } label: {
                moreTile("一起听", "music.note.list")
            }

            Button {
                closeMorePanel()
                router.showCall = true
            } label: {
                moreTile("通话", "phone.arrow.up.right")
            }

            Button {
                closeMorePanel()
                showScreenPanel = true
            } label: {
                moreTile("看屏幕", "record.circle")
            }

            Button {
                closeMorePanel()
                router.showSettings = true
            } label: {
                moreTile("设置", "slider.horizontal.3")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    /// 「让她看屏幕」—— 从聊天里直接开录屏，不用绕到设置去。
    ///
    /// 为什么非得在这儿也放一个：用户报「她说看不到我的屏幕」，
    /// 而录屏按钮埋在「设置 → 陪伴」里，他压根没找到，就以为功能坏了。
    /// 这里把按钮、说明、诊断三样摆在一起，点一下就知道卡在哪。
    private var screenPanel: some View {
        let companion = ScreenCompanion.shared
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ScreenCompanion.howToStart)
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BroadcastStartButton(width: 260)

                    if let problem = companion.extensionProblem {
                        Text(problem)
                            .font(.aevis(12.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(companion.diagnostics)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(ScreenCompanion.ocrLimit)
                        .font(.aevis(12))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("让她看屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { ScreenCompanion.shared.refreshFromExtension() }
        }
    }

    private func closeMorePanel() {
        withAnimation(.snappy(duration: 0.22)) {
            showMorePanel = false
        }
    }

    /// 面板里的一格：一个玻璃方块 + 一行小字。
    private func moreTile(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.aevis(20, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .aevisGlass(cornerRadius: 16)
            Text(title)
                .font(.aevis(11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
            router.showCall = true
        }
        if bridge.openListen {
            bridge.openListen = false
            router.showTogether = true
        }
    }

    // MARK: - 发送

    private func send() {
        if isSending {
            stopSending()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        send(text: text, image: nil)
    }

    /// 打断她正在生成的那句。
    private func stopSending() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        toolNote = nil
        chat.removeLastIfEmpty()
        SpeechService.shared.stop()
    }

    /// 真正干活的发送。
    ///
    /// `image` 只影响**显示**：聊天里出现一张图，而发给模型的是 `text`
    /// —— 从那张图里 OCR 出来的文字。用户要的就是这个：
    /// 「走的还是图片，只不过 TA 那边收到的是文字识别的东西。」
    private func send(text: String, image: Data?) {
        if isSending { stopSending() }

        errorText = nil
        toolNote = nil
        SpeechService.shared.stop()

        chat.append(ChatMessage(role: .user, text: text, imageData: image))
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
    /// 界面密度（0.82 紧凑 / 1.0 标准 / 1.22 宽松）。只乘在留白上。
    var density: Double = 1.0
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
    private var horizontalPadding: CGFloat { (simpleMode ? 16 : 14) * CGFloat(theme.density) }
    private var verticalPadding: CGFloat { (simpleMode ? 13 : 10) * CGFloat(theme.density) }
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
            #if canImport(UIKit)
            if let data = message.imageData, let image = UIImage(data: data) {
                // 图就是这条消息的全部内容 —— 那张图里 OCR 出来的文字在
                // `message.text` 里，是**给她看的**，不该再显示一遍。
                pictureBubble(image)
            } else if let sticker {
                bigSticker(sticker)
            } else {
                textBubble
            }
            #else
            if let sticker {
                bigSticker(sticker)
            } else {
                textBubble
            }
            #endif
        }
    }

    private var textBubble: some View {
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

    #if canImport(UIKit)
    /// 聊天里那张图。
    ///
    /// 用 `Color.clear` 撑尺寸、图放 overlay —— 跟背景图一个路子。
    /// 直接把 `scaledToFill` 摆进布局里会把整棵布局撑大（这条踩过）。
    private func pictureBubble(_ image: UIImage) -> some View {
        let size = Self.pictureSize(for: image)
        return Color.clear
            .frame(width: size.width, height: size.height)
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    /// 图上显示的尺寸：按原始比例缩到框里，不拉伸。
    private static func pictureSize(for image: UIImage) -> CGSize {
        let maxWidth: CGFloat = 200
        let maxHeight: CGFloat = 260
        let width = image.size.width
        let height = image.size.height
        guard width > 0, height > 0 else { return CGSize(width: 120, height: 120) }
        let scale = min(maxWidth / width, maxHeight / height, 1)
        return CGSize(width: max(60, width * scale), height: max(60, height * scale))
    }
    #endif

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
