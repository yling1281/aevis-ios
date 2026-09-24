import AVFoundation
import Foundation
import Speech

/// 听 —— 把用户说的话转成文字。
///
/// 之前只有「说」（SpeechService），没有「听」，所以实时通话做不了。
/// 这里补上：麦克风 → 系统语音识别（中文）→ 一句说完就回调。
///
/// 几个必须处理的现实问题：
/// - **采样率可能是 0**（模拟器、没有输入设备）。这时装 tap 会直接崩，所以要先判。
/// - **不能重复 removeTap**：没装过就移，某些系统版本会抛异常。
/// - **静音判句**：系统识别没有"一句说完了"的回调，只能靠「多久没新内容」来判。
/// - 播放音乐和录音要能共存，所以 AudioSession 用 `.playAndRecord` + `.mixWithOthers`。
final class ListenService: ObservableObject {
    static let shared = ListenService()

    /// 语音识别不可用（比如这台机器没装中文包）。
    enum ListenError: LocalizedError {
        case unavailable
        case noInput
        case denied

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "这台设备的语音识别暂时用不了（可能没下中文语音包）。"
            case .noInput:
                return "找不到可用的麦克风输入。"
            case .denied:
                return "麦克风或语音识别的权限没给。去「设置 → 隐私与安全性」里给 Aevis 打开。"
            }
        }
    }

    @Published private(set) var isListening = false
    /// 正在说的这句话（实时滚动）
    @Published private(set) var transcript = ""
    /// 0~1 的音量，用来画波形
    @Published private(set) var level: Double = 0
    @Published var errorText: String?

    /// 一句话说完（静音一小会儿）时回调。
    var onUtterance: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var lastChangeAt = Date()
    private var tapInstalled = false
    private var startedAt = Date()

    private init() {}

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    // MARK: - 权限

    func requestPermission() async -> Bool {
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechGranted else { return false }

        let micGranted = await withCheckedContinuation { continuation in
            // iOS 17 起用 AVAudioApplication；AVAudioSession.recordPermission 已废弃
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return micGranted
    }

    // MARK: - 开始 / 停止

    func start() throws {
        guard !isListening else { return }
        guard let recognizer else { throw ListenError.unavailable }
        guard recognizer.isAvailable else { throw ListenError.unavailable }

        let session = AVAudioSession.sharedInstance()
        // 和音乐共存：一起听的时候她还要能听见你说话
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 采样率为 0 时装 tap 会崩（模拟器就是这样）
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw ListenError.noInput
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 能在本地识别就本地识别 —— 隐私更好，也更快
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        // 没装过就别 removeTap —— 某些系统版本上这会抛异常（不是返回失败，是崩）
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.publishLevel(from: buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()

        transcript = ""
        startedAt = Date()
        lastChangeAt = Date()
        isListening = true
        errorText = nil

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    // 结果可能是「增量修正」，所以直接替换而不是追加
                    if text != self.transcript {
                        self.transcript = text
                        self.lastChangeAt = Date()
                    }
                }
            }
            if error != nil {
                // 识别出错就当这句说完了，别把界面卡在"正在听"
                DispatchQueue.main.async { self.flushUtterance() }
            }
        }

        startSilenceWatch()
    }

    @discardableResult
    func stop() -> String {
        let tail = transcript
        stopEngine()
        return tail
    }

    private func stopEngine() {
        guard isListening || tapInstalled else { return }
        isListening = false

        silenceTimer?.invalidate()
        silenceTimer = nil

        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil

        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )

        transcript = ""
        level = 0
    }

    /// 把当前这句交出去，并清空继续听。
    private func flushUtterance() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        lastChangeAt = Date()
        guard text.count >= 1 else { return }
        onUtterance?(text)
    }

    // MARK: - 静音判句

    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, self.isListening else { return }
            guard !self.transcript.isEmpty else { return }
            // 一秒多没有新内容，就认为这句说完了
            if Date().timeIntervalSince(self.lastChangeAt) > 1.3 {
                self.flushUtterance()
            }
        }
    }

    // MARK: - 音量

    private func publishLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for index in 0..<count {
            let value = channel[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(count))
        // 说话时的 RMS 大概 0.01~0.2，乘一下映射到 0~1
        let normalized = min(1.0, max(0.0, Double(rms) * 11))

        DispatchQueue.main.async { [weak self] in
            self?.level = normalized
        }
    }
}
