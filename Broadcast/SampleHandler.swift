import CoreImage
import CoreMedia
import ReplayKit
import UIKit
import Vision

/// 系统级录屏扩展 —— 这是 iOS 上**唯一**能录到整个屏幕（不只 Aevis 自己）的办法。
///
/// 所有录屏直播类 App 走的都是这条路：主 App 只是提供一个按钮，
/// 真正收画面的是这个跑在**独立进程**里的扩展。
/// 用户开始录之后，哪怕切到微信、抖音，扩展也一直在收帧。
///
/// 隐私：画面**不出手机、也不落盘**。每一帧只在内存里缩到很小、
/// 本机 OCR 出文字，然后**只把文字**写进 App Group 共享容器。
///
/// 省电：默认 4 秒才认一帧，不是逐帧识别 —— 逐帧 OCR 会把这台手机烤了。
final class SampleHandler: RPBroadcastSampleHandler {

    /// 多久认一次字。
    private let ocrInterval: TimeInterval = 4
    /// 多久往共享容器写一次「我还活着」。比认字稀疏，省点闪存。
    private let stateInterval: TimeInterval = 12
    /// 认字前把帧缩到这个宽度 —— 手机截图是 1290×2796 这种尺寸，
    /// 原图直接扔给 Vision 又慢又容易在扩展的内存上限上翻车。
    private let targetWidth: CGFloat = 720

    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private var frames = 0
    private var hits = 0
    private var lastOCRAt = Date.distantPast
    private var lastStateAt = Date.distantPast
    private var lastText = ""
    private var busy = false

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        reportState(running: true)
    }

    override func broadcastPaused() {
        reportState(running: false)
    }

    override func broadcastResumed() {
        reportState(running: true)
    }

    override func broadcastFinished() {
        reportState(running: false)
    }

    // MARK: - 收帧

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }

        let now = Date()
        lock.lock()
        let shouldOCR = !busy && now.timeIntervalSince(lastOCRAt) >= ocrInterval
        let shouldReport = now.timeIntervalSince(lastStateAt) >= stateInterval
        if shouldOCR {
            lastOCRAt = now
            busy = true
            frames += 1
        }
        if shouldReport {
            lastStateAt = now
        }
        let frameIndex = frames
        let hitIndex = hits
        lock.unlock()

        if shouldReport {
            ScreenShareStore.shared.markRunning(true, frames: frameIndex, hits: hitIndex)
        }
        guard shouldOCR else { return }

        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            finishRound()
            return
        }
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            finishRound()
            return
        }
        recognize(UIImage(cgImage: cgImage))
    }

    // MARK: - 认字

    private func recognize(_ image: UIImage) {
        guard let small = Self.shrink(image, toWidth: targetWidth),
              let cgImage = small.cgImage else {
            finishRound()
            return
        }

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self else { return }
            defer { self.finishRound() }
            guard error == nil,
                  let results = request.results as? [VNRecognizedTextObservation] else { return }

            let raw = results.compactMap { $0.topCandidates(1).first?.string }
            let text = ScreenShareStore.condense(raw.joined(separator: "\n"))

            self.lock.lock()
            let fresh = ScreenShareStore.isFresh(text, comparedTo: self.lastText)
            if fresh {
                self.lastText = text
                self.hits += 1
            }
            let snapshot = (self.frames, self.hits)
            self.lock.unlock()

            guard fresh else { return }
            ScreenShareStore.shared.append(text)
            ScreenShareStore.shared.markRunning(true, frames: snapshot.0, hits: snapshot.1)
        }
        // `.fast` 就够用了 —— 我们要的是「屏幕上大概是什么」，
        // 不是把每个字都认准。准确度换来的时间在这是浪费电。
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try handler.perform([request])
            } catch {
                // perform 抛错时 completion **不一定会被叫到** ——
                // 那就手动收尾。否则 busy 会永远卡住，之后再也认不了字。
                self?.finishRound()
            }
        }
    }

    /// 这一轮结束（认出来了，或者半路出错）。
    private func finishRound() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    private func reportState(running: Bool) {
        lock.lock()
        let snapshot = (frames, hits)
        lock.unlock()
        ScreenShareStore.shared.markRunning(running, frames: snapshot.0, hits: snapshot.1)
    }

    // MARK: - 零件

    /// 缩到指定宽度再交给 Vision。
    /// 只是缩小、不转方向 —— 像素缓冲给过来的方向就是对的。
    static func shrink(_ image: UIImage, toWidth width: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard size.width > width else { return image }

        let scale = width / size.width
        let target = CGSize(width: width, height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
