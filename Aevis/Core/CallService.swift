import Combine
import Foundation
import SwiftUI

/// 实时通话。
///
/// 真的能通：麦克风 → 识别成文字 → 发给模型 → 用语音念出来 → 继续听。
///
/// 说不到"电话级"的地方我写明白：
/// - **只能前台通话**。App 一到后台系统就收回麦克风，所以这是"开着屏幕的电话"。
/// - **没有抢话**。她说完你才能说 —— 真要能打断得做回声消除，那是另一件事。
/// - 她说的时候**主动把麦克风关掉**，否则她会把自己念的话当成你说的（回环）。
/// - 系统语音合成**没有「念完了」的回调**，所以只能轮询 `isSpeaking`。
///   连续两次都安静才算说完 —— 只判断一次会因为远程 TTS 还在加载而误判。
///
/// **故意不加 `@MainActor`**：这个单例会在 View 的属性初始化里被取到，
/// 加了隔离反而会让「非隔离上下文访问主线程成员」变成编译错误。
/// 需要在主线程改状态的地方，都在 `Task { @MainActor in ... }` 里做。
final class CallService: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case active
    }

    static let shared = CallService()

    @Published private(set) var state: State = .idle
    @Published private(set) var startedAt: Date?
    /// 你正在说的话（实时）
    @Published private(set) var listeningText = ""
    /// 她刚说的一句
    @Published private(set) var lastSaid = ""
    @Published private(set) var thinking = false
    @Published private(set) var muted = false
    @Published var errorText: String?

    private var persona = Persona()
    private var config = LLMConfig(baseURL: "", apiKey: "", model: "")
    private var memory: [String] = []

    private let listen = ListenService.shared
    private var transcriptWatch: AnyCancellable?
    private var speakingWatch: Task<Void, Never>?

    private init() {}

    var isActive: Bool { state == .active }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - 开始 / 挂断

    func start(persona: Persona, config: LLMConfig, memory: [String]) async {
        guard state == .idle else { return }
        self.persona = persona
        self.config = config
        self.memory = memory
        errorText = nil
        lastSaid = ""
        listeningText = ""
        muted = false
        state = .connecting

        guard await listen.requestPermission() else {
            errorText = ListenService.ListenError.denied.errorDescription
            state = .idle
            return
        }
        guard listen.isAvailable else {
            errorText = ListenService.ListenError.unavailable.errorDescription
            state = .idle
            return
        }

        listen.onUtterance = { [weak self] text in
            Task { @MainActor in
                await self?.handle(text)
            }
        }

        // 把她正在听的内容显示在通话界面上
        transcriptWatch = listen.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.listeningText = text
            }

        do {
            try listen.start()
        } catch {
            errorText = error.localizedDescription
            listen.onUtterance = nil
            transcriptWatch = nil
            state = .idle
            return
        }

        startedAt = Date()
        state = .active
    }

    func hangUp() {
        speakingWatch?.cancel()
        speakingWatch = nil
        transcriptWatch?.cancel()
        transcriptWatch = nil
        listen.onUtterance = nil
        listen.stop()
        SpeechService.shared.stop()
        state = .idle
        startedAt = nil
        listeningText = ""
        thinking = false
        muted = false
    }

    /// 静音（她说话的时候你自己不想被听到）。
    func toggleMute() {
        guard state == .active else { return }
        if muted {
            muted = false
            resumeListening()
        } else {
            muted = true
            listen.stop()
        }
    }

    // MARK: - 一轮对话

    private func handle(_ utterance: String) async {
        guard state == .active else { return }
        // 她说的时候不能让麦克风收着，否则会把她的声音当成你的
        listen.stop()

        ChatStore.shared.append(ChatMessage(role: .user, text: utterance))
        thinking = true

        let history = ChatStore.shared.messages.filter { !$0.text.isEmpty }
        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: history,
                memory: memory,
                tools: DeviceTools.all()
            ) {
                collected += piece
            }
        } catch {
            thinking = false
            errorText = error.localizedDescription
            resumeListening()
            return
        }

        thinking = false

        let reply = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            resumeListening()
            return
        }

        ChatStore.shared.append(ChatMessage(role: .assistant, text: reply))
        lastSaid = reply

        SpeechService.shared.speak(
            reply,
            config: AppSettings.shared.tts,
            systemVoiceIdentifier: persona.voiceIdentifier
        ) { [weak self] message in
            Task { @MainActor in
                self?.errorText = message
            }
        }

        waitUntilSheStopsTalking()
    }

    /// 等她把话说完，再把麦克风打开。
    private func waitUntilSheStopsTalking() {
        speakingWatch?.cancel()
        speakingWatch = Task { @MainActor in
            // 远程 TTS 是异步起的，先给它一点时间，不然第一下一定判成"没在说"
            try? await Task.sleep(nanoseconds: 900_000_000)

            var quietTicks = 0
            while !Task.isCancelled {
                if SpeechService.shared.isSpeaking {
                    quietTicks = 0
                } else {
                    quietTicks += 1
                    if quietTicks >= 2 { break }
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }

            guard !Task.isCancelled else { return }
            self.resumeListening()
        }
    }

    private func resumeListening() {
        guard state == .active, !muted else { return }
        do {
            try listen.start()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - 显示

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
