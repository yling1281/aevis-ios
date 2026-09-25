import CoreImage
import CoreMedia
import Foundation
import ReplayKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 录屏陪伴：她「看着」你在干什么。
///
/// **两条通道**，能力完全不同，所以必须分开说清楚：
///
/// 1. **系统级**（要的就是这个）—— 走独立的「录屏扩展」。
///    用户点一下开始，之后**哪怕切到微信、抖音**，扩展也一直在收画面。
///    这是 iOS 上唯一能录整个屏幕的办法。
///    扩展在本机 OCR，只把**文字**写进 App Group 容器；画面不落盘、不联网。
///
/// 2. **App 内**（兜底）—— `RPScreenRecorder.startCapture`。
///    不用扩展、不需要额外签名，但**只看得到 Aevis 自己**的界面，
///    切出去她就看不见了。留着是因为万一扩展因为签名装不上，至少还有一条路。
///
/// 两条可以同时开，文字汇到一起给她。
final class ScreenCompanion: ObservableObject {
    static let shared = ScreenCompanion()

    // ——— 通道一：App 内 ———

    @Published private(set) var inAppActive = false
    @Published private(set) var frameCount = 0
    @Published private(set) var hitCount = 0
    @Published private(set) var lastLookAt: Date?

    // ——— 通道二：系统级（扩展在另一个进程里跑）———

    @Published private(set) var systemRunning = false
    @Published private(set) var systemFrames = 0
    @Published private(set) var systemHits = 0
    @Published private(set) var systemLastAt: Date?

    /// 她「看到」的内容（两条通道合在一起，新的在前）。
    @Published private(set) var observations: [String] = []
    @Published private(set) var lastSeen = ""
    @Published var errorText: String?

    /// App 内通道每隔多少秒看一眼。系统级那个间隔由扩展自己定（4 秒）。
    @Published var interval: Double = 20

    /// 认出新内容时回调（用来顺手告诉她）。
    var onObservation: ((String) -> Void)?

    /// 这台设备能不能用 App 内抓帧。**每次现问**，不在初始化里取 ——
    /// ReplayKit 的 `shared()` 有线程要求，而这个单例可能从后台线程第一次被拿到
    /// （她的工具就可能在后台线程问它）。
    var isInAppAvailable: Bool {
        RPScreenRecorder.shared().isAvailable
    }

    /// 任意一条通道在给我看，就算在陪。
    var active: Bool {
        inAppActive || systemRunning
    }

    /// 共享容器能不能用。**不能用等于扩展白装** —— 它认出的字传不回来。
    var extensionUsable: Bool {
        ScreenShareStore.shared.isUsable
    }

    var extensionProblem: String? {
        ScreenShareStore.shared.unavailableReason
    }

    private let context = CIContext()
    private var lastGrabAt = Date.distantPast
    private var lastText = ""
    private var working = false
    private var inAppLog: [(text: String, at: Date)] = []
    private var pollTimer: Timer?

    private init() {}

    // MARK: - 通道一：App 内

    func start() {
        guard !inAppActive else { return }
        guard isInAppAvailable else {
            errorText = "这台设备不支持 App 内抓帧（模拟器就是这样）。真机上才能用。"
            return
        }

        inAppActive = true
        errorText = nil
        lastGrabAt = .distantPast
        lastText = ""

        let recorder = RPScreenRecorder.shared()
        // 不要麦克风 —— 我们只要画面，录声音会跟通话/听歌抢音频
        recorder.isMicrophoneEnabled = false

        recorder.startCapture { [weak self] buffer, type, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.errorText = "抓帧出错：\(error.localizedDescription)"
                    self.inAppActive = false
                }
                return
            }
            guard type == .video else { return }
            self.maybeLook(at: buffer)
        } completionHandler: { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.errorText = "开不了录屏：\(error.localizedDescription)"
                self?.inAppActive = false
            }
        }
    }

    func stop() {
        if inAppActive {
            inAppActive = false
            RPScreenRecorder.shared().stopCapture { _ in }
        }
        stopPolling()
    }

    // MARK: - App 内：看

    private func maybeLook(at buffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastGrabAt) >= interval else { return }
        guard !working else { return }
        lastGrabAt = now

        guard let pixel = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        let frame = UIImage(cgImage: cgImage)

        working = true
        Task { @MainActor in
            defer { self.working = false }
            self.frameCount += 1
            self.lastLookAt = Date()
            let text = await AttachmentService.recognizeText(in: frame)
            self.accept(text)
        }
    }

    /// 认到的文字和上一次差不多就没必要再提 —— 你多半只是在看同一页。
    @MainActor
    private func accept(_ raw: String) {
        let cleaned = ScreenShareStore.condense(raw)
        guard ScreenShareStore.isFresh(cleaned, comparedTo: lastText) else { return }

        lastText = cleaned
        lastSeen = cleaned
        hitCount += 1
        inAppLog.insert((text: cleaned, at: Date()), at: 0)
        if inAppLog.count > 20 { inAppLog.removeLast() }
        rebuildObservations()
        onObservation?(cleaned)
    }

    // MARK: - 通道二：系统级
    //
    // 扩展在**另一个进程**里写文件，主 App 只能主动去读 ——
    // 没有推送、没有回调，这是唯一的办法。

    /// 读一次扩展那边的进度。读盘放后台，赋值回主线程。
    func refreshFromExtension() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let store = ScreenShareStore.shared
            let state = store.readState()
            let entries = store.readEntries()
            // 光看 running 不够：扩展被系统杀掉时没机会上报「我停了」
            let live = store.isLive()
            DispatchQueue.main.async {
                guard let self else { return }
                self.systemFrames = state.frames
                self.systemHits = state.hits
                self.systemLastAt = state.updatedAt
                self.systemRunning = live
                self.systemEntries = entries
                self.rebuildObservations()
                if let newest = self.observations.first, newest != self.lastSeen {
                    self.lastSeen = newest
                }
            }
        }
    }

    /// 界面在前台时轮询 —— 5 秒一次，两次小文件读，可以忽略不计。
    func startPolling() {
        guard pollTimer == nil else { return }
        refreshFromExtension()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFromExtension()
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 把扩展攒下来的清掉（两条通道一起）。
    func clearHistory() {
        ScreenShareStore.shared.clear()
        systemEntries = []
        inAppLog = []
        observations = []
        lastSeen = ""
        lastText = ""
        frameCount = 0
        hitCount = 0
        systemFrames = 0
        systemHits = 0
        lastLookAt = nil
        systemLastAt = nil
        systemRunning = false
    }

    // MARK: - 合并

    private var systemEntries: [ScreenShareStore.Entry] = []

    private func rebuildObservations() {
        var pairs: [(text: String, at: Date)] = inAppLog
        pairs.append(contentsOf: systemEntries.map { (text: $0.text, at: $0.at) })

        var seen = Set<String>()
        var out: [String] = []
        for pair in pairs.sorted(by: { $0.at > $1.at }) {
            guard !seen.contains(pair.text) else { continue }
            seen.insert(pair.text)
            out.append(pair.text)
            if out.count >= 20 { break }
        }
        observations = out
    }

    // MARK: - 给用户看的实情

    /// 一行说清「现在到底在不在工作」。
    /// 用户反馈过「开了录屏她还是看不到」—— 光一个开关判断不出断在哪一环，
    /// 所以把两条通道各自的进度都摊开。
    var diagnostics: String {
        var lines: [String] = []

        if systemRunning {
            lines.append("系统级：正在录（\(systemFrames) 帧 · 认出文字 \(systemHits) 次）")
        } else {
            lines.append("系统级：没在录")
        }

        if inAppActive {
            lines.append("App 内：开着（\(frameCount) 帧 · 认出文字 \(hitCount) 次）")
        } else if isInAppAvailable {
            lines.append("App 内：关着")
        } else {
            lines.append("App 内：这台设备不支持（模拟器就是这样）")
        }

        if let last = systemLastAt ?? lastLookAt {
            let seconds = Int(Date().timeIntervalSince(last))
            lines.append("最后一次看到内容：\(seconds <= 3 ? "刚刚" : "\(seconds) 秒前")")
        }

        // 把「实际用了哪个应用组」也摊出来 ——
        // 万一共享容器还是不通，这一行就是唯一能定位的线索。
        lines.append(ScreenShareStore.diagnosticLine)
        return lines.joined(separator: "\n")
    }

    /// 系统级那条该怎么开 —— 直接抄。
    static let howToStart = """
    点下面的「开始录屏」，从系统弹出的列表里选「Aevis 录屏」。
    也可以从控制中心：长按录屏按钮 → 选 Aevis 录屏。
    开始之后状态栏会有一个红点，这时候你切到微信、抖音，她都看得到。
    """

    /// 屏幕上没有文字的内容（图片、视频）她认不出来 —— 这是 OCR 的边界，不是 bug。
    static let ocrLimit = """
    她看到的是屏幕上的文字，所以图片、视频里的内容她看不到。
    这样也不用把画面传出去，隐私留在本机。
    """
}
