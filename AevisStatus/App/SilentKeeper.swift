import AVFoundation
import Foundation

/// 「后台不掉线」用的静音保活。
///
/// iOS 会把后台 App 挂起 —— 一旦被挂起，定时上报和位置回调就全停了。
/// 让 App 长期待在后台的唯一办法是**在后台放音频**
/// （Info.plist 里的 `UIBackgroundModes = [audio]`）。
/// 所以这里循环播一段**完全静音**的音频：听不见，但系统认为你在放音乐。
///
/// ⚠️ 两条前提缺一不可：
/// 1. Info.plist 里有 `UIBackgroundModes = [audio]`（这个包的 plist 里已经有了）；
/// 2. `AVAudioSession` 是 `.playback`，而且**真的在播**。
///
/// ⚠️ 类别用 `.playback` + `options: []`（**故意不带 `.mixWithOthers`**）——
///    `AVAudioSession` 全进程唯一，一旦带上任何「混音」选项，
///    系统就不认我们这台 App 是当前播放方，锁屏控件会当场消失（见 `AudioSession.swift`）。
///
/// ⚠️ 它**费电**，所以是「开着总开关才启」的东西 —— 用户关掉上报时它也没必要转。
final class SilentKeeper {

    static let shared = SilentKeeper()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silence())
            player.numberOfLoops = -1      // 一直循环
            player.volume = 0              // 一点声音都没有
            player.prepareToPlay()
            guard player.play() else { return }
            self.player = player
            isRunning = true
        } catch {
            // 保活失败不该影响别的功能：静默放弃，界面上照常显示采集 / 上报结果。
            isRunning = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isRunning = false
    }

    /// 现造一段 1 秒的静音 WAV（44.1kHz 单声道 16 位）。
    ///
    /// 为什么现造而不是放个音频资源：少一个文件，也不用担心资源没被打进包。
    private static func silence(seconds: Double = 1.0) -> Data {
        let sampleRate = 44_100
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * 2

        var out = Data()
        func put(_ text: String) { out.append(Data(text.utf8)) }
        func put32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        func put16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }

        put("RIFF"); put32(UInt32(36 + dataBytes)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))   // 每秒字节数
        put16(2)                        // 每帧字节数
        put16(16)                       // 位深
        put("data"); put32(UInt32(dataBytes))
        out.append(Data(count: dataBytes))   // 全是 0 —— 这就是静音
        return out
    }
}
