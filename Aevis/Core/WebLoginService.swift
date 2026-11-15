import SwiftUI
import UIKit

/// 网页授权登录（2026-11-13）
///
/// 场景：浏览器打开 `aevis.cn/recharge` → 点「用 Aevis App 授权登录」→
///      系统唤起 `aevis://weblogin?t=…` → 这里弹确认框 → 用户点「允许」→
///      服务端把票标成 confirmed，**浏览器自己轮询**就拿到登录态了。
///
/// ⚠️ 授权完不要再 `openURL` 回充值页 —— 那会在 Safari 里**新开一个标签**，
///    原来那页的轮询还在原地等，用户以为没成功。
///    这里打开 `wlogin?t=…&ok=1` 只是给用户看一句「已授权，可以关掉这页了」。
@MainActor
final class WebLoginService: ObservableObject {
    static let shared = WebLoginService()

    /// 一次待确认的授权请求。`code` 是 4 位人工比对码 ——
    /// 必须和网页上显示的那个一致，用户才敢点允许。
    struct Prompt: Identifiable {
        let id = UUID()
        var ticket: String
        var code: String
        var device: String
    }

    @Published var prompt: Prompt?
    @Published var busy = false
    /// 一句给用户看的结果/错误（和 RootView 顶上的 bridgeNote 复用同一条展示）。
    @Published var notice: String?

    private init() {}

    /// 收到 `aevis://weblogin?t=…` 时调用。
    func begin(ticket raw: String) async {
        let ticket = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ticket.isEmpty else { return }
        // 没登录就没资格给别人授权 —— 直接说清楚，别让用户对着
        // 一个空白页面猜。
        guard AccountService.shared.isSignedIn else {
            notice = "先在 Aevis 里登录你的账号，再回来点一次授权。"
            return
        }
        busy = true
        defer { busy = false }
        do {
            let d = try await AccountService.shared.authedGet("/v1/web/auth/peek?t=\(ticket)")
            prompt = Prompt(ticket: ticket,
                            code: (d["code"] as? String) ?? "",
                            device: (d["device"] as? String) ?? "浏览器")
        } catch {
            notice = error.localizedDescription
        }
    }

    /// 用户点了「允许」。
    func allow() async {
        guard let p = prompt else { return }
        busy = true
        defer { busy = false }
        do {
            let d = try await AccountService.shared.authedPost("/v1/web/auth/confirm",
                                                              ["ticket": p.ticket])
            prompt = nil
            notice = "已授权，回到浏览器就能直接充值了。"
            if let s = d["redirect"] as? String, let url = URL(string: s) {
                // ⚠️ 必须写全 `options:completionHandler:` ——
                // 在 async 函数里，`open(url)` 会被重载解析到 **async 版本**，
                // 于是编译器报「expression is 'async' but is not marked with 'await'」。
                // 显式给出 completionHandler 就固定成同步那个重载了。
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
        } catch {
            prompt = nil
            notice = error.localizedDescription
        }
    }

    /// 用户点了「不允许」。
    func deny() async {
        guard let p = prompt else { return }
        prompt = nil
        _ = try? await AccountService.shared.authedPost("/v1/web/auth/cancel",
                                                       ["ticket": p.ticket])
    }
}

/// 确认框本体。保持全站那套米白 + 淡紫，不要弹系统 Alert ——
/// Alert 放不下「设备 + 验证码」两行关键信息。
struct WebLoginSheet: View {
    let prompt: WebLoginService.Prompt
    let busy: Bool
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            Image(systemName: "rectangle.and.hand.point.up.left.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color(red: 0.60, green: 0.54, blue: 0.94))
                .padding(.top, 22)

            Text("在\(prompt.device)上登录？")
                .font(.aevis(18, weight: .semibold))
                .padding(.top, 14)
                .multilineTextAlignment(.center)

            Text("确认后，那台设备就能用你的 Aevis 账号直接充值。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
                .padding(.top, 8)

            if !prompt.code.isEmpty {
                Text(prompt.code)
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .tracking(5)
                    .foregroundStyle(Color(red: 0.46, green: 0.39, blue: 0.89))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(red: 0.96, green: 0.94, blue: 1.0))
                    )
                    .padding(.top, 16)
                    .accessibilityLabel("验证码 \(prompt.code)")
            }

            Text("网页上显示的验证码应该也是这四位。对不上就别点允许。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
                .padding(.top, 10)

            Spacer(minLength: 12)

            VStack(spacing: 10) {
                Button(action: onAllow) {
                    Text(busy ? "正在授权…" : "允许登录")
                        .font(.aevis(16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(red: 0.66, green: 0.59, blue: 0.96),
                                             Color(red: 0.46, green: 0.39, blue: 0.89)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .foregroundStyle(.white)
                }
                .disabled(busy)

                Button(action: onDeny) {
                    Text("不允许")
                        .font(.aevis(15))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
        .presentationDetents([.height(430)])
        .presentationDragIndicator(.hidden)
        .background(AevisBackground(scope: .start))
        .interactiveDismissDisabled(busy)
    }
}
