import AVFoundation
import SwiftUI

/// 扫一扫（2026-11-13）
///
/// 用户要「苹果手机那个扫码的，就是手机扫码登录」——
/// 场景和安卓/小程序一样：电脑上打开 `/recharge` 或网页版聊天，
/// 手机上扫一下那张码，确认后电脑那边自动登录。
///
/// 扫到的内容可能是三种：
///   · `https://aevis.cn/wlogin?t=…`（普通二维码）
///   · `aevis://weblogin?t=…`（深链形态）
///   · 小程序码 —— 这个相机扫不出来，只能微信扫，所以这里不用管
/// 统一用 `ticket(from:)` 抠票号。
enum QRScan {
    /// 从二维码内容里抠登录票号。规则和网页 / 小程序 / 安卓完全一致。
    static func ticket(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pattern = "[?&]t=([0-9a-fA-F]{16,64})"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// 相机预览 + 二维码识别。UIViewController 那套包一层给 SwiftUI 用。
struct QRScanView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    /// 一次扫描只认第一个结果 —— 否则同一条码会被连报十几遍。
    private var handled = false
    private var configured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !configured else {
            resume()
            return
        }
        configured = true
        setup()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func setup() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return
        }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            // 只认二维码，条形码/人脸那些不要，省电也省误判
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        preview = layer

        // 授权已经给过就直接开；没问过就问一次（Info.plist 里有
        // NSCameraUsageDescription，系统弹窗会显示那句理由）。
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.startSession() }
            }
        default:
            break   // 被拒了：SwiftUI 层会显示引导文案
        }
    }

    private func startSession() {
        guard !session.isRunning else { return }
        // `startRunning()` 是阻塞调用，必须离开主线程，否则界面会卡住
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func resume() {
        handled = false
        startSession()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !handled else { return }
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = obj.stringValue, !value.isEmpty else { return }
        handled = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if session.isRunning { session.stopRunning() }
        onCode?(value)
    }
}

/// 全屏扫码页：黑底 + 取景框 + 顶部关闭。
struct QRScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// 扫到的原始字符串交给上层解析。上层负责关掉这一页再弹确认框。
    var onCode: (String) -> Void
    /// 相机被系统拒绝时的说明。
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        ZStack {
            if denied {
                Color(red: 0.086, green: 0.082, blue: 0.102).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("没有相机权限")
                        .font(.aevis(17, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("去「设置 → Aevis → 相机」打开权限，再回来扫。")
                        .font(.aevis(13))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("去设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.aevis(15, weight: .medium))
                    .padding(.horizontal, 24).padding(.vertical, 11)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
                    .foregroundStyle(.white)
                    .padding(.top, 6)
                }
            } else {
                QRScanView { code in
                    dismiss()
                    // 让 sheet 先收起来，否则 RootView 的确认框弹不出来
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onCode(code)
                    }
                }
                .ignoresSafeArea()

                // 取景框
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(red: 0.61, green: 0.54, blue: 0.94), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .overlay(alignment: .top) {
                        Text("对准电脑上的登录二维码")
                            .font(.aevis(12.5))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.42)))
                            .offset(y: -42)
                    }
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.16)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(false)
    }
}
