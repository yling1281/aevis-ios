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

    /// 这一通电话打给谁。
    ///
    /// **必须记下来**：通话能从发现页、联系人列表、`aevis://call` 任何地方拉起来，
    /// 而 `ChatStore` 只认一个 `currentID`。不记的话就会串台 ——
    /// 轻则她的回复落进别人的会话（用户在自己那边看不到，就成了「她不回我消息」），
    /// 重则 `currentID` 是 nil 时消息连盘都不落，重启就没了。
    private var contactID: UUID?

    /// 这一通电话的编号。挂断时换一个新的，
    /// 在途的那一轮就能认出「电话已经挂了」：照样把话写进聊天记录，但不再出声。
    private var session = UUID()

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

    @MainActor
    func start(persona: Persona, config: LLMConfig, memory: [String]) async {
        guard state == .idle else { return }
        BlackBox.log("☎️ 拨号 → \(persona.name.isEmpty ? "TA" : persona.name)")
        self.persona = persona
        self.config = config
        self.memory = memory
        errorText = nil
        lastSaid = ""
        listeningText = ""
        muted = false
        state = .connecting

        // 把对话切到这个人，这一通电话的上下文和落库都算在他头上。
        // 早先没这一步：从发现页或 `aevis://call` 打进来时，
        // ChatStore 还停在上一个聊过的人身上，于是她的回复全写进了别人的会话。
        contactID = PersonaStore.shared.activeID
        if let contactID {
            ChatStore.shared.switchTo(contactID)
        }
        session = UUID()

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
            BlackBox.failure("通话：麦克风起不来", detail: error.localizedDescription)
            errorText = error.localizedDescription
            listen.onUtterance = nil
            transcriptWatch = nil
            state = .idle
            return
        }

        startedAt = Date()
        state = .active
        BlackBox.log("☎️ 接通了")
    }

    func hangUp() {
        // ⚠️ 时长必须在重置 `startedAt` **之前**算出来 —— 放到后面就是 0 了。
        let seconds = elapsed
        let wasActive = state == .active
        BlackBox.log(String(format: "☎️ 挂断（%.0f 秒）", seconds))

        // 先换掉通话编号：在途的那一轮立刻能认出「电话已经挂了」——
        // 她的话照样进聊天记录（用户挂断后回到聊天能看到），
        // 但不会再念出声、也不会再把麦克风打开。
        session = UUID()
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

        // 留下一条通话记录 —— 微信那样，聊天里多一条「通话时长 03:21」。
        // 用户 2026-09-26 要的：「挂断电话的时候……像微信一样留下记录」。
        //
        // ⚠️ 3 秒以下不留：误触拨出去又马上挂的情况太多，
        // 那种记录只会把聊天记录刷满。
        guard wasActive, seconds >= 3, let contactID else { return }
        ChatStore.shared.append(
            ChatMessage(
                role: .system,
                text: "通话时长 " + Self.clock(seconds),
                kind: .call,
                callSeconds: seconds
            ),
            for: contactID
        )
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

    @MainActor
    private func handle(_ utterance: String) async {
        guard state == .active else { return }
        // 记下这一轮属于哪通电话。挂断会换掉 session，下面就能认出来。
        let token = session
        // 她说的时候不能让麦克风收着，否则会把她的声音当成你的
        listen.stop()

        ChatStore.shared.append(ChatMessage(role: .user, text: utterance), for: contactID)
        thinking = true

        // ⚠️ 用 `goesToModel` 而不是「文本非空」—— 它会把**通话记录**那种
        // 只给人看的系统消息挡在外面（否则她会学着回「通话时长 03:21」）。
        let history = ChatStore.shared.messages.filter { $0.goesToModel }
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
            if token == session { resumeListening() }
            return
        }

        thinking = false

        let reply = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            if token == session { resumeListening() }
            return
        }

        // **不管电话还在不在，她说的这句都要落进聊天记录。**
        // 用户常常是在等她回答的时候挂断的 —— 恰恰这时候丢掉最气人：
        // 电话里听到了半句，回到聊天却什么都没有。
        ChatStore.shared.append(ChatMessage(role: .assistant, text: reply), for: contactID)
        lastSaid = reply

        // 还能继续跑的前提是：这通电话还在。挂了就只把话留下，不再出声。
        guard token == session else { return }

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
