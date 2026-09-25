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
    /// 上报过「在录」但已经不再更新 —— 多半被系统回收了。和「没在录」分开说。
    @Published private(set) var systemStale = false
    @Published private(set) var systemFrames = 0
    @Published private(set) var systemHits = 0
    @Published private(set) var systemLastAt: Date?

    // ——— 通道三：环回备用通道（见 ExtensionLink）———
    //
    // 扩展把文字 POST 到 127.0.0.1 送过来。存在的唯一理由：
    // App Group 容器在重签之后有可能是 nil，那条路就断了 ——
    // 而这条不依赖任何签名能力。

    @Published private(set) var linkRunning = false
    @Published private(set) var linkFrames = 0
    @Published private(set) var linkHits = 0
    @Published private(set) var linkLastAt: Date?
    /// 备用通道**收到过东西**没有。收到过就说明这条路是通的。
    @Published private(set) var linkSeen = false

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
        inAppActive || systemRunning || linkRunning
    }

    /// 扩展把文字送回来的路通不通。**两条通道加起来看** ——
    /// 容器能用算通；容器不能用但备用通道收到过东西，也算通。
    ///
    /// 早先只认容器：签名对不上时这里恒为 false，界面就一直报
    /// 「扩展白装了」，而其实环回那条路可能活得好好的。
    var extensionUsable: Bool {
        ScreenShareStore.shared.isUsable || linkSeen
    }

    /// 屏幕现在是不是正被录制或投屏 —— **任何一种录制方式都算**，
    /// 包括控制中心那个只存相册的系统录屏。
    ///
    /// 这一条是能把话说清楚的关键。用户说「我明明在录屏，你怎么看不到」时，
    /// 光看我们自己的状态只能回一句「你没开」；有了它就能指出
    /// 「你在录，但用的不是我这个扩展，所以我拿不到内容」。
    ///
    /// 这个区别在 iOS 上是真实存在的两套东西：
    /// - **系统录屏**（控制中心那个红点）：录成视频**存进相册**，App 收不到任何画面。
    /// - **广播扩展**（我们这种）：画面交给扩展，本机 OCR 出文字再传回来，不落盘。
    /// 用户分不清太正常了 —— 两个都叫「录屏」，都会亮红点。
    ///
    /// ⚠️ `UIScreen.main` 在 iOS 16 起被标成 deprecated（建议从 window 拿），
    /// 但这里只要一个布尔、跟哪个屏幕无关，所以照用；真要改也只是消除一条警告。
    var screenIsCaptured: Bool {
        UIScreen.main.isCaptured
    }

    var extensionProblem: String? {
        // 备用通道收到过东西就说明没坏，别再把「应用组对不上」挂出来吓人。
        guard !extensionUsable else { return nil }
        return ScreenShareStore.shared.unavailableReason
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
        // 注意：**这里不能停轮询**。
        // 轮询是给「系统级录屏」读进度用的，由根视图统一管；
        // 从这里停掉会让用户关掉 App 内通道之后，系统级的进度也跟着不刷新了。
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
                self.systemStale = store.isStale()
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
        startLink()
        guard pollTimer == nil else { return }
        refreshFromExtension()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshFromExtension()
        }
    }

    /// 开环回备用通道。**幂等**，反复调不会起两份。
    private func startLink() {
        let link = ExtensionLinkListener.shared
        link.onEntry = { [weak self] text, at in
            guard let self else { return }
            self.linkSeen = true
            self.linkLastAt = at
            self.linkEntries.insert(ScreenShareStore.Entry(text: text, at: at), at: 0)
            if self.linkEntries.count > 40 { self.linkEntries.removeLast() }
            self.rebuildObservations()
            if self.observations.first != self.lastSeen, let newest = self.observations.first {
                self.lastSeen = newest
                self.onObservation?(newest)
            }
        }
        link.onState = { [weak self] running, frames, hits, at in
            guard let self else { return }
            self.linkSeen = true
            self.linkRunning = running
            self.linkFrames = frames
            self.linkHits = max(self.linkHits, hits)
            self.linkLastAt = at
        }
        link.start()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 把扩展攒下来的清掉（所有通道一起）。
    func clearHistory() {
        ScreenShareStore.shared.clear()
        systemEntries = []
        linkEntries = []
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
        systemStale = false
        linkFrames = 0
        linkHits = 0
        linkLastAt = nil
        linkRunning = false
    }

    // MARK: - 合并

    private var systemEntries: [ScreenShareStore.Entry] = []

    /// 备用通道收到的，只活在内存里（见 ExtensionLink）。
    private var linkEntries: [ScreenShareStore.Entry] = []

    private func rebuildObservations() {
        var pairs: [(text: String, at: Date)] = inAppLog
        pairs.append(contentsOf: systemEntries.map { (text: $0.text, at: $0.at) })
        pairs.append(contentsOf: linkEntries.map { (text: $0.text, at: $0.at) })

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

        if systemRunning || linkRunning {
            let frames = max(systemFrames, linkFrames)
            let hits = max(systemHits, linkHits)
            lines.append("系统级：正在录（\(frames) 帧 · 认出文字 \(hits) 次）")
        } else if systemStale {
            // 和「没在录」分开说：一个要重开，一个还没开过
            lines.append("系统级：开过，但已经不再更新了（多半被系统掐掉了）—— 重新点一次「开始录屏」")
        } else {
            lines.append("系统级：没在录")
        }

        // 备用通道单独说一句。它是「应用组对不上」时唯一的救命路，
        // 所以通没通必须能一眼看出来 —— 这台机器上就靠这一行定位。
        if linkSeen {
            lines.append("备用通道：通（拿到 \(linkHits) 条 · 上报 \(linkFrames) 帧）")
        } else if ExtensionLinkListener.shared.isListening {
            lines.append("备用通道：在听，还没收到东西")
        } else {
            lines.append("备用通道：没起来（端口被占？）")
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

        // 屏幕正在被录、但录的人不是我们 —— 用户最容易误会的一种情况。
        // 他明明看到状态栏有红点，界面上却说「没在录」，看着就像功能坏了。
        if !systemRunning, !inAppActive, screenIsCaptured {
            lines.append(
                "⚠️ 屏幕现在确实在录，但用的不是 Aevis 的扩展 —— "
                + "多半是控制中心那个系统录屏（只把视频存相册）。"
                + "要停掉它，再从上面那个「开始录屏」按钮选「Aevis 录屏」。"
            )
        }

        // 把「实际用了哪个应用组」也摊出来 ——
        // 万一共享容器还是不通，这一行就是唯一能定位的线索。
        lines.append(ScreenShareStore.diagnosticLine)
        return lines.joined(separator: "\n")
    }

    /// 系统级那条该怎么开 —— 直接抄。
    static let howToStart = """
    点下面的「开始录屏」，系统会弹出列表，选「Aevis 录屏」。
    ⚠️ 控制中心那个录屏按钮是「系统录屏」：它把视频存进相册，她看不到。
    两个都会亮红点，但只有「Aevis 录屏」会把画面给到她（只在本机认文字，不存相册）。
    选对之后切到微信、抖音，她照样看得到。
    """

    /// 屏幕上没有文字的内容（图片、视频）她认不出来 —— 这是 OCR 的边界，不是 bug。
    static let ocrLimit = """
    她看到的是屏幕上的文字，所以图片、视频里的内容她看不到。
    这样也不用把画面传出去，隐私留在本机。
    """
}
