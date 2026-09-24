import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatStore

    @State private var draft = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var showSettings = false
    @State private var sendTask: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    private var persona: Persona { personaStore.persona }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messageList
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
        // 键盘上方给一个明确的「收起」，比只靠手势可靠
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起") { composerFocused = false }
            }
        }
        .onDisappear {
            sendTask?.cancel()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 11) {
            AevisAvatar(size: settings.simpleMode ? 40 : 36, seed: persona.avatarSeed)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.name)
                    .font(.system(size: settings.simpleMode ? 18 : 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isSending ? "正在输入…" : "在线")
                    .font(.system(size: settings.simpleMode ? 13 : 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                composerFocused = false
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .aevisGlass(cornerRadius: 20)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 消息列表

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
                            accent: settings.accentColor,
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
            // 手指一拖就收，不用先把键盘拖回去
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
                .font(.system(size: settings.simpleMode ? 19 : 17, weight: .medium))
                .foregroundStyle(.primary)
            if settings.isConfigured {
                Text("说点什么开始吧。你们聊过的每一句，都会被记得。")
                    .font(.system(size: settings.simpleMode ? 15 : 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("还差一步：右上角设置 →「模型接入」，填上你的 API Key，TA 才会说话。")
                    .font(.system(size: settings.simpleMode ? 15 : 13.5))
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
                .font(.system(size: 12.5))
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
    // 玻璃要整条加在容器上，不能加在 TextField 上 ——
    // 画在自带样式的输入框上不生效，之前底部就看不到玻璃。

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: settings.simpleMode ? 17 : 15))
                .focused($composerFocused)
                .disabled(isSending)
                .padding(.vertical, settings.simpleMode ? 11 : 9)
                .padding(.leading, 15)
                .padding(.trailing, 4)

            Button(action: send) {
                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: settings.simpleMode ? 16 : 14, weight: .bold))
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
            .padding(.trailing, 7)
            .padding(.bottom, 6)
        }
        .aevisGlass(cornerRadius: 26)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var placeholder: String {
        persona.name.isEmpty ? "说点什么…" : "和 \(persona.name) 说点什么…"
    }

    // MARK: - 发送

    private func send() {
        if isSending {
            sendTask?.cancel()
            sendTask = nil
            isSending = false
            chat.removeLastIfEmpty()
            SpeechService.shared.stop()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        errorText = nil
        SpeechService.shared.stop()

        chat.append(ChatMessage(role: .user, text: text))
        chat.append(ChatMessage(role: .assistant, text: ""))

        let config = settings.llm
        let prompt = persona.systemPrompt
        let history = chat.messages.filter { !($0.role == .assistant && $0.text.isEmpty) }
        let shouldSpeak = settings.speakerEnabled
        let ttsConfig = settings.tts
        let systemVoice = persona.voiceIdentifier

        isSending = true
        sendTask = Task { @MainActor in
            var accumulated = ""
            do {
                for try await piece in LLMService.streamReply(
                    config: config,
                    systemPrompt: prompt,
                    history: history
                ) {
                    accumulated += piece
                    chat.replaceLast(with: accumulated)
                }
                chat.commit()
            } catch {
                chat.removeLastIfEmpty()
                if (error as? CancellationError) == nil {
                    errorText = error.localizedDescription
                }
            }

            isSending = false
            sendTask = nil

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

private struct MessageBubble: View {
    let message: ChatMessage
    let persona: Persona
    var accent: Color = AppSettings.accentPalette[0]
    var simpleMode: Bool = false

    /// 对方那一侧：气泡左边至少留这么多空白，也就限制了气泡最大宽度。
    /// 用「单侧 Spacer 的 minLength」而不是写死像素宽度，这样任何屏幕尺寸都自适应。
    private static let userGap: CGFloat = 88

    /// 自己那一侧：头像 26 + 间距 8 = 34，再加 54 与 userGap 对称。
    private static let assistantGap: CGFloat = 54

    private var isUser: Bool { message.role == .user }

    private var bubbleFontSize: CGFloat { simpleMode ? 17.5 : 15.5 }
    private var horizontalPadding: CGFloat { simpleMode ? 16 : 14 }
    private var verticalPadding: CGFloat { simpleMode ? 13 : 10 }
    private var bubbleCorner: CGFloat { simpleMode ? 20 : 18 }

    @ViewBuilder
    private var bubble: some View {
        if isUser {
            bubbleText.background(
                RoundedRectangle(cornerRadius: bubbleCorner, style: .continuous)
                    .fill(accent)
            )
        } else {
            bubbleText.aevisGlass(cornerRadius: bubbleCorner)
        }
    }

    private var bubbleText: some View {
        Text(message.text.isEmpty ? "…" : message.text)
            .font(.system(size: bubbleFontSize))
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }

    var body: some View {
        if isUser {
            // 只放一个 Spacer。放两个的话剩余空白会被平分，气泡就飘到中间去了。
            HStack(spacing: 0) {
                Spacer(minLength: Self.userGap)
                bubble
            }
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                AevisAvatar(size: simpleMode ? 30 : 26, seed: persona.avatarSeed)
                bubble
                Spacer(minLength: Self.assistantGap)
            }
        }
    }
}
