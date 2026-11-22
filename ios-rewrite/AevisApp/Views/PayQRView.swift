import SwiftUI
import UIKit
import CoreImage

/// 玻璃二维码弹窗（第 3 轮扩展支付模式）。
///
/// 两种模式：
/// 1. `.webAuth`（原有，不破坏）：带登录态的扫码登录/支付，走 `POST /v1/web/auth/qr` +
///    `GET /v1/web/auth/poll?t=`，status pending/scanned/cancelled/expired/ok，成功回调 `onResult`。
/// 2. `.payment`（新增）：微信支付。服务端下单返回的 `pay_url`（易支付收银台）本地生成二维码，
///    用户微信扫码付款后点「我已支付」→「正在确认支付」→ 轮询 `verify` 查单：
///      - 到账 → `onPaid(result)`（调用方弹成功动效）；
///      - 未到账 → 回到二维码并提示「支付失败，请重试」（二维码全程可见，不打断）。
///
/// 视觉统一复用 `GlassComponents` 的磨砂玻璃；外层 sheet 需配 `.glassSheetBackground()`。
/// 轮询在结构化 Task 里，视图消失自动取消，不泄漏、不跨页串扰。
struct PayQRView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case webAuth(scene: String)
        case payment(payURL: String)
    }
    let mode: Mode

    /// 标题（「扫码支付」/「扫码开通会员」由调用方定）
    let title: String
    /// webAuth 成功回调（status == ok）
    var onResult: (([String: Any]) -> Void)? = nil
    /// payment 查单闭包：返回到账结果（paid=false 视为本轮未到账）
    var verify: (() async throws -> APIClient.PayVerifyResult)? = nil
    /// payment 到账回调：关闭本弹窗 + 弹成功动效由调用方处理
    var onPaid: ((APIClient.PayVerifyResult) -> Void)? = nil

    // MARK: - 初始化

    /// 原有 webAuth 模式（保持旧调用签名可用）。
    init(
        scene: String = "pay",
        title: String = "扫码支付 / 开通会员",
        onResult: @escaping ([String: Any]) -> Void
    ) {
        self.mode = .webAuth(scene: scene)
        self.title = title
        self.onResult = onResult
    }

    /// 支付模式（微信二维码 + 我已支付查单）。
    init(
        payment payURL: String,
        title: String,
        verify: @escaping () async throws -> APIClient.PayVerifyResult,
        onPaid: @escaping (APIClient.PayVerifyResult) -> Void
    ) {
        self.mode = .payment(payURL: payURL)
        self.title = title
        self.verify = verify
        self.onPaid = onPaid
    }

    // MARK: - 公共状态

    @State private var statusText = "正在准备二维码…"
    @State private var statusKind: StatusKind = .pending
    @State private var loading = false

    enum StatusKind { case pending, scanned, done, bad }

    // webAuth 专用
    @State private var qr: APIClient.WebQR? = nil

    // payment 专用
    @State private var confirming = false

    private var scene: String {
        if case .webAuth(let s) = mode { return s }
        return "pay"
    }

    private var payURL: String {
        if case .payment(let u) = mode { return u }
        return ""
    }

    // MARK: - 二维码来源

    /// webAuth：服务端返回相对路径（自带 query），拼 base + 时间戳防缓存。
    private var qrImageURL: URL? {
        guard let qr, !qr.qrURL.isEmpty else { return nil }
        let sep = qr.qrURL.contains("?") ? "&" : "?"
        let path = qr.qrURL + sep + "_=" + String(Int(Date().timeIntervalSince1970))
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: APIClient.base + path)
    }

    /// payment：把 pay_url 字符串本地生成二维码（CIQRCodeGenerator，M 级纠错）。
    private var localQRImage: UIImage? {
        guard !payURL.isEmpty else { return nil }
        guard let data = payURL.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = out.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return UIImage(ciImage: scaled)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            GlassBackdrop()
            switch mode {
            case .webAuth: webAuthBody
            case .payment: paymentBody
            }
        }
        .task {
            if case .webAuth = mode { await newQR() }
        }
    }

    // MARK: - webAuth 视图（原逻辑）

    private var webAuthBody: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(AE.accent)
                .multilineTextAlignment(.center)

            Text("用 Aevis App 或小程序扫码，二维码已带当前登录态")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)
                if let u = qrImageURL {
                    AsyncImage(url: u) { img in
                        img.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(width: 204, height: 204)
                } else if loading {
                    ProgressView()
                } else {
                    Text("二维码加载失败\n点「刷新二维码」重试")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .glassCard(cornerRadius: 18, material: .regular, tintOpacity: 0.6)

            if let qr, !qr.code.isEmpty {
                Text("设备验证码 \(qr.code)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AE.accent)
            }

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

                Button { Task { await newQR() } } label: {
                    Text(loading ? "生成中…" : "刷新二维码")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(AE.accentDeep, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    // MARK: - payment 视图（新增）

    private var paymentBody: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(AE.accent)
                .multilineTextAlignment(.center)

            Text("请用微信扫一扫付款，完成后点「我已支付」")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)
                if let img = localQRImage {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 204, height: 204)
                } else {
                    Text("二维码生成失败\n请关闭后重试")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                }
                if confirming {
                    ZStack {
                        Color.white.opacity(0.82)
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
            .glassCard(cornerRadius: 18, material: .regular, tintOpacity: 0.6)

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
                            (confirming || localQRImage == nil)
                                ? AE.accentDeep.opacity(0.45) : AE.accentDeep,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(confirming || localQRImage == nil)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: confirming)
        .onAppear {
            if !payURL.isEmpty {
                statusKind = .pending
                statusText = "等待扫码付款…"
            } else {
                statusKind = .bad
                statusText = "收银台地址为空，请关闭后重试"
            }
        }
    }

    private var statusColor: Color {
        switch statusKind {
        case .done: return AE.accent
        case .bad: return Color.hex(0xE5484D)
        case .scanned: return AE.warm
        case .pending: return AE.textSecondary
        }
    }

    // MARK: - 行为：webAuth

    /// 新建二维码并启动轮询（对齐 qrlogin.js 的 newQr + startPoll）
    private func newQR() async {
        await MainActor.run {
            loading = true
            qr = nil
            statusKind = .pending
            statusText = "正在准备二维码…"
        }
        do {
            let info = try await APIClient.webAuthQR(scene: scene, token: session.token)
            await MainActor.run {
                qr = info
                statusText = "等待手机扫码…"
            }
            await poll(ticket: info.ticket)
        } catch {
            await MainActor.run {
                statusKind = .bad
                statusText = "二维码生成失败：\(error.localizedDescription)"
                loading = false
            }
        }
    }

    /// 轮询：立即一次 + 每 2 秒，直到 ok/cancelled/expired 或视图销毁。
    private func poll(ticket: String) async {
        await MainActor.run { loading = false }
        guard !ticket.isEmpty else { return }
        while !Task.isCancelled {
            do {
                let d = try await APIClient.webAuthPoll(ticket: ticket, token: session.token)
                let st = (d["status"] as? String) ?? "pending"
                if st == "ok" {
                    await MainActor.run {
                        statusKind = .done
                        statusText = "已完成，正在更新…"
                    }
                    onResult?(d)
                    return
                }
                if st == "scanned" {
                    await MainActor.run {
                        statusKind = .scanned
                        statusText = "已扫码，请在手机上点「允许」"
                    }
                } else if st == "cancelled" {
                    await MainActor.run {
                        statusKind = .bad
                        statusText = "已取消，点「刷新二维码」重试"
                    }
                    return
                } else if st == "expired" {
                    await MainActor.run {
                        statusKind = .bad
                        statusText = "二维码过期了，点「刷新二维码」"
                    }
                    return
                }
            } catch {
                // 网络抖动下一轮再说（对齐 qrlogin.js 的空 catch）
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    // MARK: - 行为：payment（我已支付 → 查单）

    /// 点「我已支付」后：置 confirming → 每 2 秒查单，最多 12 次（约 24 秒）。
    /// 到账 → onPaid；超时未到账 → 回二维码 + 失败提示；网络抖动本轮重试不中断。
    private func confirmPayment() async {
        guard let verify, !confirming else { return }
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
                onPaid?(paidResult)   // 调用方关闭弹窗并弹成功动效
            } else {
                // 二维码全程可见（未被替换），这里只改状态提示即可「回到二维码」
                statusKind = .bad
                statusText = "支付失败，请确认已付款后点「我已支付」重试"
            }
        }
    }
}
