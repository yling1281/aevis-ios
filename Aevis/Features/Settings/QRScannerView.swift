import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 扫二维码。用 AVFoundation 的元数据输出 —— 比 VisionKit 那套
/// （`DataScannerViewController`）要求低，老机器也能用。
///
/// 认到第一段码就回调一次，然后自己停掉 —— 免得同一个码被连报十几遍。
struct QRScannerView: UIViewControllerRepresentable {
    /// 认到一段文本。
    var onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static var isAvailable: Bool {
        #if canImport(UIKit)
        return AVCaptureDevice.default(for: .video) != nil
        #else
        return false
        #endif
    }

    // MARK: - 控制器

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

        var onFound: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        /// 认到一次就够了，别再重复回调。
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stop()
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // ⚠️ 这一行必须在 addOutput **之后** —— 在那之前 availableMetadataObjectTypes 还是空的。
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            // startRunning 是阻塞的，不能放主线程 —— 放主线程会卡住界面
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }

        private func stop() {
            guard session.isRunning else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.session.stopRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !delivered else { return }
            for object in metadataObjects {
                guard let code = object as? AVMetadataMachineReadableCodeObject,
                      let text = code.stringValue, !text.isEmpty else { continue }
                delivered = true
                stop()
                onFound?(text)
                return
            }
        }
    }
}
