import CoreImage
import CoreMedia
import Foundation
import ReplayKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 录屏陪伴：她"看着"你在干什么。
///
/// 做法（**不传画面出去**）：系统录屏抓帧 → 在本地用系统 OCR 认出屏幕上的文字
/// → 只把**文字**交给她。所以：
/// - 不需要多模态模型，任何纯文本模型都能用
/// - 不联网传图，隐私留在本机
///
/// 三个现实约束：
/// - **模拟器不支持**（`isAvailable` 为 false），所以 CI 截图里会显示"这台设备不支持"；
/// - 抓帧很费电，所以默认 **20 秒一帧**，不是实时视频；
/// - 屏幕上是图片、聊天头像这类**没有文字**的内容时，她"看不到" —— 如实说清楚。
final class ScreenCompanion: ObservableObject {
    static let shared = ScreenCompanion()

    @Published private(set) var active = false
    /// 这台设备能不能抓帧。**每次现问**，不在初始化里取 ——
    /// ReplayKit 的 `shared()` 有线程要求，而这个单例可能从后台线程第一次被拿到
    /// （她的工具就可能在后台线程问它）。
    var isAvailable: Bool {
        RPScreenRecorder.shared().isAvailable
    }
    /// 她"看到"的内容（新的在前）
    @Published private(set) var observations: [String] = []
    @Published private(set) var lastSeen = ""
    @Published var errorText: String?

    /// 每隔多少秒看一次。
    @Published var interval: Double = 20

    /// 认出新内容时回调（用来顺手告诉她）。
    var onObservation: ((String) -> Void)?

    private let context = CIContext()
    private var lastGrabAt = Date.distantPast
    private var lastText = ""
    private var working = false

    private init() {}

    // MARK: - 开关

    func start() {
        guard !active else { return }
        guard isAvailable else {
            errorText = "这台设备不支持录屏抓帧（模拟器就是这样）。真机上才能用。"
            return
        }

        active = true
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
                    self.active = false
                }
                return
            }
            guard type == .video else { return }
            self.maybeLook(at: buffer)
        } completionHandler: { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.errorText = "开不了录屏：\(error.localizedDescription)"
                self?.active = false
            }
        }
    }

    func stop() {
        guard active else { return }
        active = false
        RPScreenRecorder.shared().stopCapture { _ in }
    }

    // MARK: - 看

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
            let text = await AttachmentService.recognizeText(in: frame)
            self.accept(text)
        }
    }

    /// 认到的文字和上一次差不多就没必要再提 —— 你多半只是在看同一页。
    @MainActor
    private func accept(_ raw: String) {
        let cleaned = Self.condense(raw)
        guard cleaned.count >= 4 else { return }
        guard cleaned != lastText else { return }

        // 简单的相似判断：新内容里大部分字符和上一次重叠，就当作没变
        if Self.similarity(cleaned, lastText) > 0.8 { return }

        lastText = cleaned
        lastSeen = cleaned
        observations.insert(cleaned, at: 0)
        if observations.count > 20 { observations.removeLast() }
        onObservation?(cleaned)
    }

    /// 把一屏散乱的文字压成一句像话的东西。
    static func condense(_ raw: String) -> String {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .prefix(12)
            .joined(separator: " / ")
    }

    /// 0~1，越大越像。用「两个字一组」的重合度粗略估算 ——
    /// 不需要多准，只要能挡住"同一页反复上报"就够了。
    static func similarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let a = Set(bigrams(left))
        let b = Set(bigrams(right))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return characters.map(String.init) }
        var out: [String] = []
        for index in 0..<(characters.count - 1) {
            out.append(String(characters[index...(index + 1)]))
        }
        return out
    }
}
