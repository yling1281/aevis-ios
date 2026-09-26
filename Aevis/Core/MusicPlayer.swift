import AVFoundation
import Foundation
import MediaPlayer

/// 独立播放器。
///
/// 用 AVPlayer 直接播网易给的临时地址 ——
/// 不接 Apple Music，也不需要额外的音乐 App，
/// 所以它在后台、在锁屏都能继续放（音频会话设成 `.playback`）。
///
/// 锁屏和灵动岛要显示的东西都通过 `MPNowPlayingInfoCenter` 发布，
/// 她之后要做灵动岛，直接用这里的数据就行。
final class MusicPlayer: NSObject, ObservableObject {

    static let shared = MusicPlayer()

    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var index: Int = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var lyric: String = ""
    @Published private(set) var errorText: String?

    /// 留一句话给界面显示。
    /// `errorText` 保持只读（免得各处乱改它），只在这里开一个写入口 ——
    /// 快捷指令让她放歌时，「没登录」「没找到」这些得说出来。
    func note(_ text: String?) {
        errorText = text
    }

    /// 换歌时回调，给「一起听」用 —— 她可以就着这首歌说点什么。
    var onTrackChanged: ((MusicTrack) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    /// 上面那个观察者**注册在哪台 player 上**。
    ///
    /// ⚠️ 必须和 `timeObserver` **成对保存**。踩过的血案（用户报「点歌就闪退」）：
    /// `loadCurrent()` 是先把 `player` 换成新的、再调 `observeProgress`，
    /// 而里面用 `self.player?.removeTimeObserver(旧token)` —— 拿**旧 token**
    /// 去**新的 player** 上移除，AVFoundation 直接抛异常，App 当场闪退。
    /// 路径极短：搜歌 → 点一首 → 再点一首（第二次 `loadCurrent` 必炸）。
    private var observedPlayer: AVPlayer?
    private var loadingTask: Task<Void, Never>?

    var current: MusicTrack? {
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    private override init() {
        super.init()
        configureSession()
        configureRemoteCommands()
    }

    // MARK: - 音频会话与远程控制

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        // .playback：后台也能播。mixWithOthers 让别人说话时不用暂停音乐
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { await self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { await self?.previous() }
            return .success
        }
    }

    // MARK: - 播放控制

    /// 换一批歌并从第一首开始。
    func play(_ tracks: [MusicTrack], startingAt start: Int = 0) async {
        guard !tracks.isEmpty else { return }
        queue = tracks
        index = min(max(start, 0), tracks.count - 1)
        await loadCurrent()
    }

    /// 接着当前队列放某一首。
    func play(queue tracks: [MusicTrack], index target: Int) async {
        guard tracks.indices.contains(target) else { return }
        queue = tracks
        index = target
        await loadCurrent()
    }

    func resume() {
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func toggle() {
        isPlaying ? pause() : resume()
    }

    func next() async {
        guard !queue.isEmpty else { return }
        index = (index + 1) % queue.count
        await loadCurrent()
    }

    func previous() async {
        guard !queue.isEmpty else { return }
        index = (index - 1 + queue.count) % queue.count
        await loadCurrent()
    }

    func seek(to ratio: Double) {
        guard let player, duration > 0 else { return }
        let target = CMTime(seconds: ratio * duration, preferredTimescale: 600)
        player.seek(to: target)
    }

    func stop() {
        loadingTask?.cancel()
        // ⚠️ 趁 player 还活着先把观察者摘掉 —— 下面 `player = nil` 之后就再也没机会了
        // （那颗 token 只能交回注册它的那台实例）。
        if let timeObserver, let old = observedPlayer {
            old.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil
        player?.pause()
        player = nil
        isPlaying = false
        queue = []
        index = -1
        progress = 0
        duration = 0
        lyric = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 加载

    private func loadCurrent() async {
        guard let track = current else { return }

        // 黑匣子：点歌这条链最容易崩，每一步都留一行 ——
        // 下次再闪退，看最后停在哪一行就知道死在哪了。
        BlackBox.log("放歌《\(track.title)》id=\(track.id)")

        loadingTask?.cancel()
        errorText = nil
        progress = 0
        // 时长来自接口，偶尔会是 0 或者 NaN（网易那边偶尔就不给）。
        // 后面进度条是拿它做除数的，所以这里就夹成「一个正常的非负数」。
        duration = track.duration.isFinite && track.duration > 0 ? track.duration : 0
        lyric = ""

        onTrackChanged?(track)

        // 歌词是附属信息，拿不到不影响播放
        let lyricTask = Task { [id = track.id] in
            if let text = try? await NeteaseClient.shared.lyric(for: id) {
                await MainActor.run { self.lyric = text }
            }
        }

        do {
            let url = try await NeteaseClient.shared.playableURL(for: track.id)
            BlackBox.log("拿到播放地址，开始建播放器")
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            observeProgress(of: newPlayer)
            newPlayer.play()
            isPlaying = true
            updateNowPlaying()
            BlackBox.log("已经在放了")
        } catch {
            BlackBox.failure("放歌失败", detail: error.localizedDescription)
            errorText = error.localizedDescription
            isPlaying = false
        }

        _ = lyricTask
    }

    private func observeProgress(of player: AVPlayer) {
        // ⚠️ 摘观察者必须用**当初注册它的那台实例**（见 `observedPlayer` 的说明）。
        // 顺带解释另一个症状：旧观察者以前从来没被真正摘掉过，
        // 于是一路活着继续回调 —— 上一首的状态盖到下一首上、还会反复触发 next()，
        // 表现就是「歌自己乱跳」。
        if let timeObserver, let old = observedPlayer {
            // 这里就是上次「点歌闪退」的案发现场，留一行日志 ——
            // 万一还有别的路径会崩，黑匣子里能看见它到底走到没走到这一句。
            BlackBox.log("摘掉上一首的进度观察者")
            old.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        observedPlayer = nil

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, let player else { return }
            // 换歌之后旧 player 的回调可能还在路上 —— 只认当前这首。
            guard player === self.observedPlayer else { return }

            // ⚠️ 必须挡一下 NaN。AVPlayer 在"还没就绪 / 流有问题 / 刚 seek"这些时刻
            // 会给一个 NaN 的时间，而 NaN 会顺着 progress 一路传到界面的 Slider 上 ——
            // **NaN 进 SwiftUI 就是崩溃**。这里拦一道，比在界面里到处防要省事。
            let seconds = time.seconds
            if seconds.isFinite, seconds >= 0 {
                self.progress = seconds
            }

            let total = player.currentItem?.duration.seconds ?? 0
            if total.isFinite, total > 0 {
                self.duration = total
            }
            // 放完了自动下一首
            if let item = player.currentItem, item.status == .readyToPlay,
               self.duration > 0, self.progress >= self.duration - 0.4 {
                Task { await self.next() }
            }
        }
        observedPlayer = player
    }

    private func updateNowPlaying() {
        guard let track = current else { return }

        // ⚠️ 锁屏 / 控制中心那套只认「正常的数」。
        // 把 NaN 或者无穷大塞进去是**没有意义的**，所以先夹一下 ——
        // 上一处 NaN 已经在进度回调里挡掉了，这里是同一路的第二道。
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeProgress = progress.isFinite && progress >= 0 ? progress : 0

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: safeDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: safeProgress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = track.album
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 截图自检
    //
    // CI 上跑的是模拟器：没有网易云登录、也放不出声。播放界面要是空着，
    // 截出来就是一片「还没在放歌」，没法确认界面做对了没有。
    // 所以塞一首假歌进去 —— **只在 Debug 生效**，真机上没有这条路。

    #if DEBUG
    func seedDemo() {
        queue = [
            MusicTrack(
                id: "0",
                title: "晴天",
                artist: "周杰伦",
                album: "叶惠美",
                duration: 269,
                url: nil
            )
        ]
        index = 0
        duration = 269
        progress = 62
        lyric = """
        [00:00.00] 晴天 - 周杰伦
        [00:58.00] 故事的小黄花
        [01:02.00] 从出生那年就飘着
        [01:06.00] 童年的荡秋千
        [01:10.00] 随记忆一直晃到现在
        """
        isPlaying = true
    }
    #endif

    // MARK: - 给播放界面和「一起听」用的歌词

    /// 解析好的歌词（`[mm:ss.xx] 内容` 那套格式）。
    ///
    /// **缓存一份**：一首歌的歌词好几 KB、上百行，而 `progress` 每 0.5 秒跳一次，
    /// 每次都重新解析会白白烧掉不少 CPU —— 播放界面上会明显看到卡顿。
    private var lineCache: (source: String, lines: [(time: Double, text: String)]) = ("", [])

    private var lyricLines: [(time: Double, text: String)] {
        if lineCache.source == lyric { return lineCache.lines }
        let lines = Self.parse(lyric)
        lineCache = (lyric, lines)
        return lines
    }

    /// 唱到第几句了。没有就是 nil。
    var lyricCursor: Int? {
        let lines = lyricLines
        guard !lines.isEmpty else { return nil }
        return lines.lastIndex(where: { $0.time <= progress + 0.2 })
    }

    /// 当前这一句歌词（去掉时间轴）。她可以就着这句吐槽。
    var currentLyricLine: String? {
        guard let index = lyricCursor else { return nil }
        return lyricLines[index].text
    }

    /// 下一句（播放界面里做「下一句」的小字用）。
    var nextLyricLine: String? {
        guard let index = lyricCursor, index + 1 < lyricLines.count else { return nil }
        return lyricLines[index + 1].text
    }

    /// 把 `[01:23.45] 歌词内容` 拆成「几秒 + 文字」。
    ///
    /// 认不出来的行直接跳过 —— 歌词文件里常有 `[ti:]`、`[by:]` 这类元信息。
    private static func parse(_ raw: String) -> [(time: Double, text: String)] {
        raw.split(separator: "\n").compactMap { line -> (Double, String)? in
            guard let closing = line.firstIndex(of: "]") else { return nil }

            // ⚠️ 这一行挡的是**闪退**，不是格式问题。
            // 如果 `]` 正好在行首，下面那个 `index(after: startIndex)` 会**越过** closing，
            // 切片的起点比终点还靠后 → 范围非法 → 直接崩。
            //
            // 踩过：修好歌词接口之后，「点歌就闪退」。因为以前歌词根本拿不到，
            // 这段代码从来没有真正执行过 —— 一个潜伏了很久的崩溃被"修好"给暴露了。
            guard closing > line.startIndex else { return nil }

            let stamp = line[line.index(after: line.startIndex)..<closing]
            let parts = stamp.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }

            let text = line[line.index(after: closing)...]
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (minutes * 60 + seconds, text)
        }
    }
}
