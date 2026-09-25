import AVFoundation
import Foundation

/// 「后台不掉线」用的静音保活。
///
/// ## 为什么非要有它
/// 他在 **QQ** 里跟机器人聊天时，我们这个 App 正好在**后台** ——
/// 而 iOS 会把后台 App 挂起，WebSocket 一断她就哑了。整个功能就没意义了。
///
/// iOS 上唯一能让 App 长期待在后台的办法是**在后台放音频**
/// （Info.plist 里的 `UIBackgroundModes = [audio]`）。
/// 所以这里循环播一段**完全静音**的音频：听不见，但系统认为你在放音乐。
///
/// ⚠️ 两条前提缺一不可：
/// 1. Info.plist 里有 `UIBackgroundModes = [audio]`
/// 2. AVAudioSession 是 `.playback`、而且**真的在播**
///
/// 这是个**可以关掉的开关**（设置里），因为它确实费电 ——
/// 用户明确要求"能自定义的都自定义"，这种代价必须让他自己选。
final class SilentKeeper {

    static let shared = SilentKeeper()

    private var player: AVAudioPlayer?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // 和别人共存：用户真在放歌、打电话都不受影响（.mixWithOthers）
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let player = try AVAudioPlayer(data: Self.silence())
            player.numberOfLoops = -1      // 一直循环
            player.volume = 0              // 一点声音都没有
            player.prepareToPlay()
            guard player.play() else { return }
            self.player = player
            isRunning = true
        } catch {
            // 保活失败**不该影响别的功能**：静默放弃。
            // 表现就是"切到后台之后她就不回了"，界面上的状态会如实显示断开。
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
    /// 为什么现造而不是放个音频文件：少一个资源文件，
    /// 也省得以后有人翻到它问"这是什么东西、什么声音"。
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
