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

        loadingTask?.cancel()
        errorText = nil
        progress = 0
        duration = track.duration
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
            let item = AVPlayerItem(url: url)
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            observeProgress(of: newPlayer)
            newPlayer.play()
            isPlaying = true
            updateNowPlaying()
        } catch {
            errorText = error.localizedDescription
            isPlaying = false
        }

        _ = lyricTask
    }

    private func observeProgress(of player: AVPlayer) {
        if let timeObserver {
            self.player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.progress = time.seconds
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
    }

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = track.album
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - 给「一起听」用的歌词

    /// 当前这一句歌词（去掉时间轴）。她可以就着这句吐槽。
    var currentLyricLine: String? {
        guard !lyric.isEmpty else { return nil }
        let lines = lyric.split(separator: "\n").compactMap { raw -> (Double, String)? in
            // 形如：[01:23.45] 歌词内容
            guard let closing = raw.firstIndex(of: "]") else { return nil }
            let stamp = raw[raw.index(after: raw.startIndex)..<closing]
            let parts = stamp.split(separator: ":")
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            let text = raw[raw.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return (minutes * 60 + seconds, text)
        }

        return lines.last(where: { $0.0 <= progress + 0.2 })?.1
    }
}
