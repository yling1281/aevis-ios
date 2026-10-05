import Combine
import Foundation
import SwiftUI

/// 一起听。
///
/// ## 形态选择器已经删掉了（2026-10-02 用户拍板）
///
/// 用户原话：「一点进去，不是有一个她控制，然后网易云一起听吗？那个就不要了」
/// —— 说的是播放器里那个「同步听 / 她控制 / 一起听房间」的分段控件。
///
/// 删掉是对的：那三个形态本来就不是三种体验，而是**同一个体验的三个完成度**
/// （「一起听房间」压根没接，界面上还写着"还没接"；「她控制」只是把她的歌词
/// 碎碎念关掉）。真正该有的一直只有一种：
///
/// > **歌在这儿放，她跟着听、跟着说，而且她想切歌就切。**
///
/// 所以 `ListenTogetherMode` 这个枚举、`AppSettings.listenTogetherMode` 这个设置
/// **全部删掉**。留着它们只会有一种下场：某天有人在某个角落里又把它读出来，
/// 于是她莫名其妙不说话了（旧的 `herControl` 分支就是这么写的 ——
/// `guard mode == .sync else { return }`，选中"她控制"就等于让她闭嘴）。
///
/// ## 为什么能真的"一起"
/// 播放器里已经算出了**当前唱到哪一句**（`MusicPlayer.currentLyricLine`），
/// 所以她知道你听到哪儿了 —— 她的话是接着这一句说的，不是随便说。
///
/// 刻意不自动念出来：音乐正在放，她再说话会把人声盖掉。
/// 所以她的反应先落在面板上，想听就点旁边的小喇叭。
///
/// ⚠️ `@MainActor`（2026-09-26 补的）：它读 `MusicPlayer.shared` 的 `@Published`
/// 和 `current` / `currentLyricLine`，而 `MusicPlayer` 现在是 `@MainActor` 的 ——
/// 不加这个，编译直接报「main actor-isolated property cannot be accessed
/// from outside of the actor」。它的调用方全是视图（本来就在主线程），
/// 加上没有任何副作用。
@MainActor
final class ListenTogetherService: ObservableObject {
    static let shared = ListenTogetherService()

    @Published private(set) var active = false
    /// 她的实时反应（新的在前）
    @Published private(set) var herLines: [String] = []
    @Published private(set) var thinking = false
    @Published var statusLine: String?

    /// 每几句歌词说一次。太少会吵，太多就没参与感。
    @Published var linesPerComment: Int = 3
    /// 两次开口之间至少隔多久（秒）—— 就算歌词刷得快，也不会连珠炮。
    @Published var minimumGap: Double = 25

    private var cancellable: AnyCancellable?
    private var lyricCount = 0
    private var lastSpokeAt = Date.distantPast

    private var persona = Persona()
    private var config = LLMConfig(baseURL: "", apiKey: "", model: "")
    private var memory: [String] = []

    private init() {}

    var currentTrackTitle: String {
        MusicPlayer.shared.current.map { $0.display } ?? "还没放歌"
    }

    // MARK: - 开始 / 结束

    func start(persona: Persona, config: LLMConfig, memory: [String]) {
        self.persona = persona
        self.config = config
        self.memory = memory
        herLines = []
        lyricCount = 0
        lastSpokeAt = Date.distantPast
        active = true
        statusLine = nil
        // 一起听默认打开外放语音？不 —— 音乐在放，让她念会盖住歌。
        observeLyrics()
    }

    func stop() {
        active = false
        cancellable?.cancel()
        cancellable = nil
        lyricCount = 0
        // 「结束一起听」= 这一场散了，口头聊的那些也清掉。
        // ⚠️ 只是**界面上**清掉 —— 两边的话都已经进了正式聊天记录
        //    （见 `send`），所以什么都不会丢。
        chatLines = []
    }

    /// 她说的话要不要顺带念出来。只有用户主动点才念。
    func speak(_ line: String) {
        SpeechService.shared.speak(
            line,
            config: AppSettings.shared.tts,
            systemVoiceIdentifier: persona.voiceIdentifier
        )
    }

    // MARK: - 跟着歌词走

    private func observeLyrics() {
        cancellable?.cancel()
        cancellable = MusicPlayer.shared.$lyric
            .sink { [weak self] line in
                // ⚠️ 必须跳一次。`receive(on: .main)` 只保证**运行时**在主线程，
                // 编译器不认 —— `.sink` 的闭包不是 `@MainActor` 隔离的，
                // 直接在这里读 `self.active` 这些属性，
                // Swift 会报「main actor-isolated property cannot be accessed
                // from outside of the actor」（build-61 就死在这上面）。
                Task { @MainActor in self?.handleLyric(line) }
            }
    }

    /// 收到一句新歌词。**跑在主 actor 上**（上面那个 `Task` 负责跳进来）。
    private func handleLyric(_ line: String) {
        guard active else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }

        lyricCount += 1
        // 形态选择器删掉之后这里没有分支了 —— 她**永远**参与。
        // （旧代码这里是 `guard mode == .sync else { return }`，
        //   选中「她控制」就等于让她整场闭嘴。那个坑跟着枚举一起删了。）
        guard lyricCount % max(1, linesPerComment) == 0 else { return }
        guard Date().timeIntervalSince(lastSpokeAt) >= minimumGap else { return }

        Task { await react(to: trimmed) }
    }

    /// 她接着这一句歌词说一句。
    private func react(to lyric: String) async {
        guard !thinking else { return }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLine = "还没填 API Key，她没法跟着说。"
            return
        }

        thinking = true
        lastSpokeAt = Date()
        defer { thinking = false }

        let track = MusicPlayer.shared.current
        let trackLine = track.map { $0.display } ?? "一首歌"

        let instruction = """
        你们在一起听歌。
        正在放：\(trackLine)
        刚唱到这句：「\(lyric)」

        用一两句话说说你现在的感觉，就像真的在旁边一起听一样。
        可以提这句歌词给你的感觉，也可以顺着说点别的。短一点，别超过 30 个字。
        直接输出内容，不要引号，不要解释。

        ⚠️ 工具是给你**备着**的，不是让你现在就动手：除非他明确说想换歌、
        想听什么、或者让你收藏，否则不要自己切歌 / 暂停 / 收藏。
        """

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: instruction)],
                memory: memory,
                // ⚠️ **这句以前是没有的**，是一处"假装完成"的温床：
                //    她对着一句歌词说「给你换首安静的」，听起来像做了，
                //    其实手上一个工具都没有，什么都没发生。
                //    用户点名要的就是"给她切歌的权限"，所以这里必须给全。
                tools: DeviceTools.all(),
                onToolActivity: { [weak self] title in
                    Task { @MainActor in self?.statusLine = title }
                }
            ) {
                // 她开始说话了，把「她翻了翻网易云…」那行收掉 ——
                // 不然工具提示会压在她的话上面。
                if collected.isEmpty, statusLine != nil, piece.isEmpty == false {
                    statusLine = nil
                }
                collected += piece
                if collected.count > 200 { break }
            }
        } catch {
            statusLine = "她这次没接上话：\(error.localizedDescription)"
            return
        }

        let text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        herLines.insert(text, at: 0)
        if herLines.count > 30 { herLines.removeLast() }
        statusLine = nil
    }

    /// 手动让她说一句（不想等歌词的时候）。
    func pokeHer() async {
        let line = MusicPlayer.shared.currentLyricLine ?? "（还没到歌词）"
        await react(to: line)
    }

    // MARK: - 打字聊天（用户 2026-09-30 要的）

    /// 一起听时你们打出来的字。
    ///
    /// 用户原话：「我们不能两个人互相打字聊天，要加一个输入框，能互相打字聊天的」。
    ///
    /// 为什么单独一份、不直接读 `ChatStore`：她跟着歌词插的话（`herLines`）
    /// 是**播放器里才看得到**的碎碎念，不该塞进正式聊天记录；而这里打出来的字
    /// 是正经对话，要两边都留（见 `send` 里那段镜像）。
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var mine: Bool
        var text: String
    }

    @Published private(set) var chatLines: [Line] = []
    @Published private(set) var replying = false

    /// 打一句话给她，等她回。
    ///
    /// ## 三条口径
    /// 1. **两边都落进正式聊天记录**（`ChatStore`）—— 关掉播放器之后这段
    ///    不该凭空消失。她下次在聊天页里也该记得刚才聊过什么。
    ///    这跟 QQ 机器人那条是同一条规矩（见 `QQBotService.replyText`）。
    /// 2. **工具照给**（`DeviceTools.all()`）—— 她说"给你放首安静的"、
    ///    "现在几点了"，在这儿也得能做。少给一份工具就是"假装完成"的温床。
    /// 3. **带上"正在听什么"**。不然她不知道自己在什么场景里说话，
    ///    回出来的话跟歌完全没关系，那就不叫一起听了。
    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 上一条还在吐字 —— 不排队，直接说要等（排队会把她的话憋成两段）
        guard !replying else { return }

        // 先把"之前聊过什么"抓下来，再把自己这句放进去 —— 顺序反了
        // 这句会在历史里出现两次（一次作为上下文、一次作为临时指令）。
        let prior = chatLines.filter { !$0.text.isEmpty }

        chatLines.append(Line(mine: true, text: text))
        ChatStore.shared.append(ChatMessage(role: .user, text: text))
        trimChat()

        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLine = "还没填 API Key，她没法回你。"
            return
        }

        replying = true
        defer { replying = false }

        // 先占一条空位，她的字**流式**长在这条上 —— 不然要等整段生成完才出现
        let placeholder = Line(mine: false, text: "")
        chatLines.append(placeholder)
        let slot = chatLines.count - 1

        let trackLine = MusicPlayer.shared.current.map { $0.display } ?? "一首歌"
        let lyric = MusicPlayer.shared.currentLyricLine ?? "（还没到歌词）"

        var history = prior.map {
            ChatMessage(role: $0.mine ? .user : .assistant, text: $0.text)
        }
        history.append(ChatMessage(role: .user, text: """
        你们正在一起听歌，歌是「\(trackLine)」，刚唱到「\(lyric)」。
        对方刚跟你说：「\(text)」

        就像面对面聊天那样回他一句。短一点（15 个字以内），
        直接说内容，不要引号，不要解释，不要加动作描写。
        """))

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: history,
                memory: memory,
                tools: DeviceTools.all(),
                // 她调工具的那几秒界面上不能是死的 —— 和聊天页同一条口径。
                onToolActivity: { [weak self] title in
                    Task { @MainActor in self?.statusLine = title }
                }
            ) {
                collected += piece
                if chatLines.indices.contains(slot) {
                    chatLines[slot].text = collected
                }
                if collected.count > 200 { break }
            }
        } catch {
            if chatLines.indices.contains(slot) { chatLines.remove(at: slot) }
            statusLine = "她这次没接上话：\(error.localizedDescription)"
            return
        }

        let reply = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            if chatLines.indices.contains(slot) { chatLines.remove(at: slot) }
            return
        }

        chatLines[slot].text = reply
        herLines.insert(reply, at: 0)
        if herLines.count > 30 { herLines.removeLast() }
        ChatStore.shared.append(ChatMessage(role: .assistant, text: reply))
        trimChat()
        statusLine = nil
    }

    /// 聊得再久也不留一长串在内存里 —— 播放器上那个列表不是聊天页。
    private func trimChat() {
        if chatLines.count > 60 { chatLines.removeFirst(chatLines.count - 60) }
    }

    #if DEBUG
    /// 截图自检用：假装一起听开着，而且她已经说过两句。
    ///
    /// 真机上「两个人的头像」那一行要等她真的开口（得有 API Key）才出现，
    /// 模拟器里永远等不到 —— 那就截不到用户点名要看的那一块。
    /// **只在 Debug 生效。**
    func seedDemo() {
        active = true
        thinking = false
        statusLine = nil
        herLines = [
            "这句我从初中听到现在",
            "副歌前面那四小节最好听"
        ]
        // 「打字聊」那一层也要能截到 —— 空着进去只有一句提示，看不出界面长什么样。
        chatLines = [
            Line(mine: true, text: "你还记得第一次听这首歌是什么时候吗"),
            Line(mine: false, text: "记得，你上次在车里放过"),
            Line(mine: true, text: "那时候你还没理我呢"),
            Line(mine: false, text: "现在理你了，够不够")
        ]
        replying = false
    }
    #endif
}
