import Combine
import Foundation
import SwiftUI

/// 实时通话。
///
/// 真的能通：麦克风 → 识别成文字 → 发给模型 → 用语音念出来 → 继续听。
///
/// 说不到"电话级"的地方我写明白：
/// - **只能前台通话**。App 一到后台系统就收回麦克风，所以这是"开着屏幕的电话"。
/// - **没有抢话**。ta说完你才能说 —— 真要能打断得做回声消除，那是另一件事。
/// - ta说的时候**主动把麦克风关掉**，否则ta会把自己念的话当成你说的（回环）。
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
    /// ta刚说的一句
    @Published private(set) var lastSaid = ""
    @Published private(set) var thinking = false
    @Published private(set) var muted = false
    /// 免提（外放）开着没有。默认开 —— 和原来 `.defaultToSpeaker` 的行为一致。
    @Published private(set) var speakerOn = true
    @Published var errorText: String?

    /// 这一通电话被**外面**结束了几次（系统卡上的挂断 / 锁屏上的结束）。
    ///
    /// ## 为什么需要它（用户 2026-10-02 报的「挂断 APP 同步不了」）
    /// 挂断有两条来路：
    ///   · 用户点 **App 里**那个红按钮 → 那条自己会 `dismiss()`，页面跟着关；
    ///   · **系统那边**挂的 → 以前这里只把 `state` 置回 `.idle`，
    ///     而通话页是挂在 `AppRouter.showCall` 这个 `fullScreenCover` 上的 ——
    ///     **没有任何人去关那个开关**，于是"电话已经挂了，页面还杵在屏幕上"。
    ///
    /// ⚠️ 用**只增不减的计数器**而不是 Bool：连着被系统挂两通要能触发两次。
    /// ⚠️ 别让根视图直接 `@ObservedObject` 这个 `CallService` 来观察它 ——
    ///    通话中 `listeningText` 每秒会发几十次，那样整棵 Tab 都会跟着重画。
    ///    要用的去 `CallEndSignal`（那个只发这一个数）。
    @Published private(set) var remoteEndTick = 0

    private var persona = Persona()
    private var config = LLMConfig(baseURL: "", apiKey: "", model: "")
    private var memory: [String] = []

    /// 这一通电话打给谁。
    ///
    /// **必须记下来**：通话能从发现页、联系人列表、`aevis://call` 任何地方拉起来，
    /// 而 `ChatStore` 只认一个 `currentID`。不记的话就会串台 ——
    /// 轻则ta的回复落进别人的会话（用户在自己那边看不到，就成了「ta不回我消息」），
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
        BlackBox.log("☎️ 拨号 → \(persona.name.isEmpty ? "ta" : persona.name)")
        self.persona = persona
        self.config = config
        self.memory = memory
        errorText = nil
        lastSaid = ""
        listeningText = ""
        muted = false
        speakerOn = true
        state = .connecting

        // 把对话切到这个人，这一通电话的上下文和落库都算在他头上。
        // 早先没这一步：从发现页或 `aevis://call` 打进来时，
        // ChatStore 还停在上一个聊过的人身上，于是ta的回复全写进了别人的会话。
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

        // 把ta正在听的内容显示在通话界面上
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

        // 通话开始 —— 告诉 `AudioSession` 这条通道现在是通话在用：
        // 它据此决定"说话 / 录音借完之后把类别还给谁"，以及免提还是听筒。
        AudioSession.inCall = true
        AudioSession.callSpeakerOn = speakerOn
        AudioSession.applyCallOutputPort()

        // ⭐ 让系统弹它自己那套通话界面（灵动岛 / 锁屏上那张卡）。
        //
        // ⚠️ **失败是允许的**：侧载重签之后系统可能不给（资格没继承过来）。
        //    那时候我们自己的通话界面还在跑，用户完全无感 —— 见 `SystemCall`。
        if AppSettings.shared.systemCallUI {
            SystemCall.start(displayName: persona.name)
        }

        BlackBox.log("☎️ 接通了")
    }

    /// - Parameter fromSystem: 这一通是**系统那边**挂的（锁屏 / 灵动岛上的通话卡）。
    ///   带上它才会发 `remoteEndTick` —— 展示通话页的那两层据此把页面收掉。
    ///   App 自己那个红按钮走默认值（它自己会 `dismiss()`，不需要这个信号）。
    func hangUp(fromSystem: Bool = false) {
        // ⚠️ 时长必须在重置 `startedAt` **之前**算出来 —— 放到后面就是 0 了。
        let seconds = elapsed
        let wasActive = state == .active
        BlackBox.log(String(format: "☎️ 挂断（%.0f 秒）%@",
                            seconds, fromSystem ? "（系统那边挂的）" : ""))

        // 系统那边挂的 —— 先把信号发出去，免得后面任何一步提前 return 把它漏掉。
        if fromSystem { remoteEndTick &+= 1 }

        // 系统那边那通也要收掉。
        //
        // 两种来路都会走到这儿，而这一句对两边都是对的：
        //  · **我们挂的**（通话页那个红按钮 / `onDisappear`）→ 得告诉系统一声，
        //    不然灵动岛上那张卡会一直挂着"正在通话"；
        //  · **系统挂的**（用户在锁屏上按了结束）→ `SystemCallCenter` 已经把自己
        //    清干净了，这一句是幂等收尾（那边 `guard let manager` 直接收住，不会转圈）。
        SystemCall.hangUp()

        // 通话结束 —— 通道的主人换回去了。
        // ⚠️ 别忘了撤掉"强制外放"：不撤的话，下一次一起听 / 语音消息
        //    会莫名其妙从喇叭里出来，而且耳机插着也不走耳机。
        AudioSession.inCall = false
        AudioSession.applyCallOutputPort()

        // 先换掉通话编号：在途的那一轮立刻能认出「电话已经挂了」——
        // ta的话照样进聊天记录（用户挂断后回到聊天能看到），
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

    /// 静音（ta说话的时候你自己不想被听到）。
    func toggleMute() {
        guard state == .active else { return }
        setMuted(!muted)
    }

    /// **直接设定**静音状态（不是切换）。
    ///
    /// ## 为什么要单独有这个（用户 2026-10-02 报的「静音同步不了」）
    /// 系统那张通话卡上的静音按钮是个**带状态的开关**：点一下静音、再点一下取消。
    /// 它派回来的 `MuteConversationAction` 里带着 `isMuted`（**目标状态**）。
    ///
    /// 而老代码在 `SystemCallCenter` 里写的是
    /// `if state == .active, !muted { toggleMute() }` —— 把它当成了单向的：
    ///   · 卡上点「静音」→ App 这边静音 ✅
    ///   · 卡上再点「取消静音」→ `!muted` 不成立，**整段跳过** ❌
    ///     麦克风继续关着、App 上那个按钮也还亮着"已静音"，
    ///     看起来就是"点了取消没用"。
    ///
    /// 所以这里给出一个幂等的"设成某个值"，谁来设都不会串。
    /// - Parameter pushToSystem: 要不要顺带把这个状态推给系统那张通话卡。
    ///   **系统派回来的时候必须传 false** —— 那条是"它告诉我们的"，
    ///   再推回去就是自己跟自己对讲（虽然 `muted != value` 那道守卫能收住，
    ///   但让它压根不发生更干净）。
    func setMuted(_ value: Bool, pushToSystem: Bool = true) {
        guard state == .active else { return }
        guard muted != value else { return }
        if value {
            muted = true
            listen.stop()
        } else {
            muted = false
            resumeListening()
        }
        if pushToSystem { SystemCall.pushMuted(value) }
    }

    /// 免提开关（用户 2026-10-01：「第三个的话呢，可以加点功能」）。
    ///
    /// ⚠️ 这里**一个字节都不碰 `AVAudioSession`** —— 只改 `AudioSession` 上的意图。
    ///    会话是全进程唯一的，音乐、TTS、静音保活都在用；谁都能随手 `setCategory`
    ///    就意味着互相打架（锁屏播放控件就是这么弄丢的）。路由由那个文件统一落。
    func toggleSpeaker() {
        guard state == .active else { return }
        speakerOn.toggle()
        AudioSession.callSpeakerOn = speakerOn
        // 立刻生效 —— **不重开会话**。重开会让麦克风断一下，通话里听得很明显。
        AudioSession.applyCallOutputPort()
        BlackBox.tap("通话 · 免提\(speakerOn ? "开" : "关")")
    }

    /// 会话被别的东西动过之后补一次 —— **只在通话进行中生效**。
    ///
    /// 谁会动它：系统自己那套通话界面接通的那一下、来电、Siri、插拔耳机。
    /// 被改掉之后我们这边的麦克风就哑了，而用户看到的是
    /// 「ta突然听不见我说话了」——这种最难查，因为界面一切正常。
    func reassertAudioIfActive() {
        guard state == .active, !muted else { return }
        // `ListenService.start()` 在"已经听着"的时候会直接返回（不重设类别），
        // 所以先停一下再起 —— 要的正是那一次 `setCategory`。
        _ = listen.stop()
        resumeListening()
    }

    // MARK: - 一轮对话

    @MainActor
    private func handle(_ utterance: String) async {
        await respond(to: utterance)
    }

    /// 你自己**打字**发的一句（通话页那个输入框）。
    ///
    /// 用户 2026-10-01：「第三个的话呢，可以加点功能」。
    ///
    /// 为什么要有它：麦克风在吵的地方根本不好使（地铁、风大、旁边有人），
    /// 而「电话里说不出话」会让ta显得很笨。留一个能打字的入口，
    /// 这通电话就不会因为环境断掉 —— 而且**走的是和说话完全同一条路**。
    @MainActor
    func send(text raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        BlackBox.log("🎹 通话里打字：\(text.count) 字")
        await respond(to: text)
    }

    /// 一轮对话。**说出来的和打出来的都走这里** —— 两条路必须完全一样，
    /// 不然"打字那条"迟早会漏掉某一步（落库、挂断识别、念出来）。
    @MainActor
    private func respond(to utterance: String) async {
        guard state == .active else { return }
        // 记下这一轮属于哪通电话。挂断会换掉 session，下面就能认出来。
        let token = session
        // ta说的时候不能让麦克风收着，否则会把ta的声音当成你的
        listen.stop()

        ChatStore.shared.append(ChatMessage(role: .user, text: utterance), for: contactID)
        thinking = true

        // ⚠️ 用 `goesToModel` 而不是「文本非空」—— 它会把**通话记录**那种
        // 只给人看的系统消息挡在外面（否则ta会学着回「通话时长 03:21」）。
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
                // 一边收一边往屏幕上放。
                // 原来要等ta整段写完才"啪"地蹦出来，那几秒在通话里就是死机 ——
                // 屏幕上滚字，感觉就像ta正在说（AI 权限那张卡那条产品原则：
                // 「不要让ta看起来像卡住了」）。
                lastSaid = collected
            }
        } catch {
            thinking = false
            errorText = error.localizedDescription
            if token == session { resumeListening() }
            return
        }

        thinking = false

        // ⭐ 剥掉ta写在最后一行的那条心情标记（`〔心情：…｜心里话：…〕`）——
        //    通话里ta这句话既要说出口、又要落进聊天记录，标记一个字都不能露。
        //    用 `consume` 的返回值：剥标记 + 同步心情，语义跟聊天页那条主链路一致。
        let reply = MoodStore.shared.consume(collected)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            if token == session { resumeListening() }
            return
        }

        // **不管电话还在不在，ta说的这句都要落进聊天记录。**
        // 用户常常是在等ta回答的时候挂断的 —— 恰恰这时候丢掉最气人：
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

    /// 等ta把话说完，再把麦克风打开。
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

    #if DEBUG
    /// 只给截图自检用（`-aevisOpenCall`）：把界面摆成"正在通话中"。
    ///
    /// 为什么要它：模拟器里没有麦克风权限、也没有 API Key，真起一通电话
    /// 必然失败 —— 失败之后 `state` 回到 `.idle`，通话页那一层（免提按钮、
    /// 打字输入框）**根本不显示**，截出来的还是老样子，等于白截。
    /// 所以这里只造状态，不碰任何音频设备。
    func previewStart() {
        state = .active
        startedAt = Date()
        lastSaid = "嗯，我在呢。今天累不累？"
        listeningText = "今天还好，就是有点想你"
    }
    #endif
}

/// 「这一通是被系统挂断的」这**一个**信号。
///
/// ## 为什么不让视图直接观察 `CallService`
/// 需要这个信号的是**展示通话页的那两层**（`MainTabView` 的 `showCall`、
/// `CompanionCard` 的 `showCall`），而 `MainTabView` 是个大东西 ——
/// 它一旦 `@ObservedObject` 了 `CallService`，通话中 `listeningText`
/// 每秒几十次实时转写就会带着整棵 Tab 树重画几十次。
///
/// 所以单独做一个只发这一个数的对象：观察它**不产生任何额外重画**。
/// （用法：`@ObservedObject private var callEnd = CallEndSignal.shared`，
///   然后 `.onChange(of: callEnd.tick) { _, _ in … 把通话页收掉 }`。）
final class CallEndSignal: ObservableObject {

    static let shared = CallEndSignal()

    /// 只增不减。0 是初始值，别拿它当"刚挂了一通"。
    @Published private(set) var tick = 0

    private var bag: AnyCancellable?

    private init() {
        bag = CallService.shared.$remoteEndTick
            .removeDuplicates()
            // `remoteEndTick` 的写入方是 `SystemCallCenter`（`@MainActor`），
            // 所以本来就在主线程；这一句是为了"以后有人从别处改它"也不出事。
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self, value > 0 else { return }
                self.tick = value
            }
    }
}
