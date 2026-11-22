import SwiftUI
import UIKit
import CoreImage

/// 微信扫码支付弹窗：半屏 + 磨砂玻璃。
///
/// 流程：服务端下单返回 `pay_url` → 本地用 `CIQRCodeGenerator` 生成二维码 → 用户微信扫码付款
/// → 点「我已支付」→ 每 2 秒查单、最多 12 次（约 24 秒）：
///   · 到账 → `onPaid(result)`（调用方关闭弹窗并弹成功动效）；
///   · 未到账 → 二维码一直留在屏幕上，只把提示改成「支付失败，请重试」，不打断。
///
/// 版式（2026-11-22 改）：半屏磨砂卡片 —— `.presentationDetents([.fraction(0.78)])` 限高，
/// `glassSheetBackground()` 让 sheet 本身透明，内容用 `glassCard(material: .regular)` 做磨砂面板，
/// 上方留一层轻微压暗（不铺底色），背后的商城透出来，看起来就是半屏。
///
/// 二维码为什么之前是白框：`CIQRCodeGenerator` 产出的是 CIImage，
/// 旧实现直接 `UIImage(ciImage:)` 交给 `Image(uiImage:)` —— 这种 UIImage 没有 `cgImage`，
/// SwiftUI 渲染成一片空白。现在统一经 `CIContext.createCGImage` 转成 CGImage 再包 UIImage。
/// 也绝不走 `AsyncImage(url:)`：它只能加载远程/文件 URL，读不到内存里的图。
struct PayQRView: View {
    @Environment(\.dismiss) private var dismiss

    /// 收银台地址（微信扫码后打开的支付页）
    let payURL: String
    /// 标题，由调用方拼（「扫码支付 · 会员 X · 30 天」）
    let title: String
    /// 查单闭包：返回到账结果（paid == false 视为本轮未到账）
    let verify: () async throws -> APIClient.PayVerifyResult
    /// 到账回调：关弹窗 + 弹成功动效由调用方处理
    let onPaid: (APIClient.PayVerifyResult) -> Void

    @State private var qrImage: UIImage? = nil
    @State private var confirming = false
    @State private var statusKind: StatusKind = .pending
    @State private var statusText = "等待扫码付款…"

    private enum StatusKind { case pending, scanned, done, bad }

    init(
        payment payURL: String,
        title: String,
        verify: @escaping () async throws -> APIClient.PayVerifyResult,
        onPaid: @escaping (APIClient.PayVerifyResult) -> Void
    ) {
        self.payURL = payURL
        self.title = title
        self.verify = verify
        self.onPaid = onPaid
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // 上半屏只压暗、不铺底：sheet 背景透明，背后商城透出来 → 半屏观感
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            panel
        }
        .presentationDetents([.fraction(0.78)])   // iOS 16.0+ 可用
        .glassSheetBackground()                   // 16.4+ 走兼容包装，低版本退回系统默认底
        .onAppear(perform: prepare)
    }

    private var panel: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(AE.accent)
                .multilineTextAlignment(.center)

            Text("请用微信扫一扫付款，完成后点「我已支付」")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)

            qrBox

            Text(statusText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.accent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .glassCard(cornerRadius: 23, material: .thin,
                                   tintOpacity: 0.08, strokeOpacity: 0.18)
                }
                .buttonStyle(.plain)

                Button { Task { await confirmPayment() } } label: {
                    Text(confirming ? "正在确认支付…" : "我已支付")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            (confirming || qrImage == nil)
                                ? AE.accentDeep.opacity(0.45) : AE.accentDeep,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(confirming || qrImage == nil)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        // 磨砂面板：Material 糊掉背后商城 + 半透明白提亮，就是想要的那种磨砂质地
        .glassCard(cornerRadius: AE.sheetRadius, material: .regular,
                   tintOpacity: 0.42, strokeOpacity: 0.28)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.18), value: confirming)
    }

    /// 二维码白底方框：白底是给扫码识别的，不随磨砂改色。
    private var qrBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white)
                .frame(width: 220, height: 220)

            if let qrImage {
                Image(uiImage: qrImage)
                    .resizable()
                    .interpolation(.none)     // 二维码放大不做插值，否则边缘发虚扫不出来
                    .scaledToFit()
                    .frame(width: 200, height: 200)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.hex(0xE5484D))
                    Text("二维码生成失败\n请关闭后重新下单")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(width: 200, height: 200)
            }

            if confirming {
                ZStack {
                    Color.white.opacity(0.86)
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在确认支付…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AE.accent)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity)
            }
        }
        .frame(width: 220, height: 220)
        .glassCard(cornerRadius: 18, material: .regular, tintOpacity: 0.6)
    }

    private var statusColor: Color {
        switch statusKind {
        case .done: return AE.accent
        case .bad: return Color.hex(0xE5484D)
        case .scanned: return AE.warm
        case .pending: return AE.textSecondary
        }
    }

    // MARK: - 二维码生成

    private func prepare() {
        qrImage = Self.makeQRImage(payURL)
        if payURL.isEmpty {
            statusKind = .bad
            statusText = "收银台地址为空，请关闭后重试"
        } else if qrImage == nil {
            statusKind = .bad
            statusText = "二维码生成失败，请关闭后重新下单"
        } else {
            statusKind = .pending
            statusText = "等待扫码付款…"
        }
    }

    /// pay_url → 二维码。放大 12 倍再用 CIContext 转 CGImage，
    /// `UIImage(cgImage:)` 才有位图数据，`Image(uiImage:)` 才画得出来。
    private static func makeQRImage(_ text: String) -> UIImage? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")   // M 级纠错：容错与密度平衡
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - 行为：我已支付 → 查单

    /// 点「我已支付」后：置 confirming → 每 2 秒查单，最多 12 次（约 24 秒）。
    /// 到账 → onPaid；超时未到账 → 回二维码 + 失败提示；网络抖动本轮跳过不中断。
    private func confirmPayment() async {
        guard !confirming else { return }
        await MainActor.run {
            confirming = true
            statusKind = .scanned
            statusText = "正在确认支付…"
        }

        var paidResult: APIClient.PayVerifyResult? = nil
        for _ in 0..<12 {
            if Task.isCancelled { return }
            do {
                let r = try await verify()
                if r.paid {
                    paidResult = r
                    break
                }
            } catch {
                // 查单网络错误：本轮跳过，下一轮重试
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        await MainActor.run {
            confirming = false
            if let paidResult {
                statusKind = .done
                statusText = "支付成功"
                onPaid(paidResult)   // 调用方关闭弹窗并弹成功动效
            } else {
                // 二维码全程可见（没被替换），这里只改状态提示即可「回到二维码」
                statusKind = .bad
                statusText = "支付失败，请确认已付款后点「我已支付」重试"
            }
        }
    }
}
