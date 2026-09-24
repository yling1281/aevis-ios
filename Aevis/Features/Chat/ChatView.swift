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
        .onDisappear {
            sendTask?.cancel()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 11) {
            AevisAvatar(size: 36, seed: persona.avatarSeed)

            VStack(alignment: .leading, spacing: 1) {
                Text(persona.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isSending ? "正在输入…" : "在线")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .aevisGlass(cornerRadius: 19)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if chat.messages.isEmpty {
                        emptyState
                    }

                    ForEach(chat.messages) { message in
                        MessageBubble(message: message, persona: persona)
                            .id(message.id)
                    }

                    if let errorText {
                        errorBubble(errorText)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
            .scrollDismissesKeyboard(.interactively)
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
        VStack(spacing: 14) {
            AevisOrb()
                .scaleEffect(0.72)
                .frame(height: 150)
            Text("她在这儿。")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
            if settings.isConfigured {
                Text("说点什么开始吧。你们聊过的每一句，她都会记得。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("还差一步：右上角设置 →「模型接入」，填上你的 API Key，她才会说话。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
    }

    private func errorBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.orange.opacity(0.14))
                )
            Spacer(minLength: 30)
        }
    }

    // MARK: - 输入栏

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 15))
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .aevisGlass(cornerRadius: 20)
                .disabled(isSending)

            Button(action: send) {
                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(
                            isSending
                                ? Color.gray.opacity(0.55)
                                : (canSend ? Color(red: 0.42, green: 0.35, blue: 0.95) : Color.gray.opacity(0.35))
                        )
                    )
                    .contentShape(Circle())
            }
            .disabled(!canSend && !isSending)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        errorText = nil

        chat.append(ChatMessage(role: .user, text: text))
        chat.append(ChatMessage(role: .assistant, text: ""))

        let config = settings.llm
        let prompt = persona.systemPrompt
        let history = chat.messages.filter { !($0.role == .assistant && $0.text.isEmpty) }
        let shouldSpeak = settings.speakerEnabled
        let rate = settings.speechRate
        let voice = persona.voiceIdentifier

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
                SpeechService.shared.speak(accumulated, voiceIdentifier: voice, rate: rate)
            }
        }
    }
}

// MARK: - 气泡

private struct MessageBubble: View {
    let message: ChatMessage
    let persona: Persona

    private var isUser: Bool { message.role == .user }

    private var bubbleText: some View {
        Text(message.text.isEmpty ? "…" : message.text)
            .font(.system(size: 15.5))
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .textSelection(.enabled)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if isUser {
                Spacer(minLength: 52)
            } else {
                AevisAvatar(size: 26, seed: persona.avatarSeed)
            }

            if isUser {
                bubbleText.background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.42, green: 0.35, blue: 0.95))
                )
                Spacer(minLength: 6)
            } else {
                bubbleText.aevisGlass(cornerRadius: 18)
                Spacer(minLength: 52)
            }
        }
    }
}
