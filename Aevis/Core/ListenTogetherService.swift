import Combine
import Foundation
import SwiftUI

/// 「一起听」的三种形态。
enum ListenTogetherMode: String, Codable, CaseIterable, Identifiable {
    case sync
    case herControl
    case neteaseRoom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sync: return "同步听"
        case .herControl: return "\(Pronoun.current)控制"
        case .neteaseRoom: return "一起听房间"
        }
    }

    var explanation: String {
        switch self {
        case .sync:
            return "歌在这台手机上放，\(Pronoun.current)跟着一起听，隔几句说一句自己在听什么。"
        case .herControl:
            return "播放器交给\(Pronoun.current) —— 你说「换首安静的」，\(Pronoun.current)自己去找、自己切。"
        case .neteaseRoom:
            return "进网易云自己的「一起听」房间。需要逆向它的房间接口，现在还没接。"
        }
    }

    /// 这个形态真做了没有。**没做的就照实说**，不假装能用。
    var isImplemented: Bool {
        self != .neteaseRoom
    }
}

/// 一起听。
///
/// 为什么能真的"一起"：
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
    @Published private(set) var mode: ListenTogetherMode = .sync
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

    func start(mode: ListenTogetherMode, persona: Persona, config: LLMConfig, memory: [String]) {
        self.mode = mode
        self.persona = persona
        self.config = config
        self.memory = memory
        herLines = []
        lyricCount = 0
        lastSpokeAt = Date.distantPast
        active = true

        statusLine = mode.isImplemented
            ? nil
            : "「一起听房间」还没接，先用另外两种。"
        // 一起听默认打开外放语音？不 —— 音乐在放，让她念会盖住歌。
        observeLyrics()
    }

    func stop() {
        active = false
        cancellable?.cancel()
        cancellable = nil
        lyricCount = 0
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
        // 她控制模式下不需要她念歌词 —— 那是她在操作播放器
        guard mode == .sync else { return }
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
        """

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: instruction)],
                memory: memory
            ) {
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

    #if DEBUG
    /// 截图自检用：假装一起听开着，而且她已经说过两句。
    ///
    /// 真机上「两个人的头像」那一行要等她真的开口（得有 API Key）才出现，
    /// 模拟器里永远等不到 —— 那就截不到用户点名要看的那一块。
    /// **只在 Debug 生效。**
    func seedDemo() {
        active = true
        mode = .sync
        thinking = false
        statusLine = nil
        herLines = [
            "这句我从初中听到现在",
            "副歌前面那四小节最好听"
        ]
    }
    #endif
}
