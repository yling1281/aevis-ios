import SwiftUI

/// 微信登录（2026-11-02）
///
/// ## 为什么是「扫码」不是「一键授权」
/// 微信开放平台那套**移动应用登录**要有审核通过的应用、要嵌 SDK、还要配
/// Universal Links —— 我们这边没有。但**小程序**那条路是通的，
/// 后端 `/v1/auth/wx/qr/*` 早就做好了：
///
///   ① `create` 出一张带一次性 ticket 的**小程序码**（App 只显示图，拿不到 ticket 明文）；
///   ② 用户用微信扫码 → 进我们自己的 `pages/wxauth` → 小程序把登录态写回 ticket；
///   ③ 这里每 2 秒 poll 一次，拿到 token 就当场登录。
///
/// 所以这一页的作用只有一个：**把那张码摆在用户面前，并盯着它**。
struct WXLoginSheet: View {
    /// 登录成功 —— 外面不用做事（`RootView` 盯着 `isSignedIn` 会整棵树换掉）。
    var onDone: () -> Void

    @ObservedObject private var account = AccountService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var ticket: AccountService.WXLoginTicket?
    @State private var errorText: String?
    @State private var expired = false
    @State private var secondsLeft = 180
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("用微信登录")
                    .font(.aevis(V2.title, weight: .semibold))
                Spacer(minLength: 8)
                Button {
                    dismiss()
                } label: {
                    Text("关闭")
                        .font(.aevis(V2.sub))
                        .foregroundStyle(V2.dim(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, V2.gutter)
            .padding(.top, 20)

            ScrollView {
                VStack(spacing: 16) {
                    codeCard
                    hintCard
                    if let errorText {
                        Text(errorText)
                            .font(.aevis(V2.tiny))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    retryButton
                }
                .padding(.horizontal, V2.gutter)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .v2Page()
        .task { await start() }
    }

    // MARK: - 码

    private var codeCard: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                    .fill(V2.card)
                RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                    .strokeBorder(V2.stroke, lineWidth: 0.5)
                    .allowsHitTesting(false)

                if loading {
                    ProgressView()
                } else if let url = ticket?.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .padding(14)
                        case .failure:
                            V2Empty("码没加载出来", hint: "点下面的「换一张」")
                        default:
                            ProgressView()
                        }
                    }
                } else {
                    V2Empty("码没生成出来", hint: "点下面的「换一张」")
                }
            }
            .frame(height: 268)

            Text(expired ? "这张码过期了，换一张" : "用微信扫一下，进去点「确认登录」")
                .font(.aevis(V2.sub))
                .foregroundStyle(expired ? Color.orange : V2.dim(0.55))
                .multilineTextAlignment(.center)
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("1", "手机微信扫上面的码")
            row("2", "会打开 Aevis 小程序的一个确认页")
            row("3", "点「确认登录」，这里会自动跳进 App")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                .fill(V2.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                .strokeBorder(V2.stroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }

    private func row(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.aevis(V2.micro, weight: .semibold))
                .foregroundStyle(V2.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(V2.soft(0.14)))
            Text(text)
                .font(.aevis(V2.tiny))
                .foregroundStyle(V2.dim(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var retryButton: some View {
        Button {
            Task { await start() }
        } label: {
            Text(loading ? "正在生成…" : "换一张")
                .font(.aevis(V2.sub, weight: .medium))
                .foregroundStyle(V2.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(V2.soft(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    // MARK: - 要票 + 盯着票

    private func start() async {
        loading = true
        expired = false
        errorText = nil
        ticket = nil

        do {
            let t = try await account.wxLoginTicket()
            ticket = t
            secondsLeft = t.expiresIn
            loading = false
            await watch(t)
        } catch {
            loading = false
            errorText = error.localizedDescription
        }
    }

    /// 每 2 秒问一句「确认了吗」。**不无限等** —— 票过期就停，让用户自己点「换一张」。
    private func watch(_ t: AccountService.WXLoginTicket) async {
        var waited = 0
        while waited < t.expiresIn + 4 {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            waited += 2
            secondsLeft = max(0, t.expiresIn - waited)

            do {
                let status = try await account.pollWXLogin(ticket: t.ticket)
                if case .done = status {
                    onDone()
                    dismiss()
                    return
                }
            } catch {
                // 「已过期 / 会话不存在」这类就别再敲了 —— 继续轮询只会一直报错。
                // 这两种后端会明确写进 msg，按文字认一下就够（不值得为它加一个错误类型）。
                let text = error.localizedDescription
                if text.contains("过期") || text.contains("不存在") {
                    expired = true
                    return
                }
                // 其余的（网络抖一下）就当没发生，下一轮继续问
            }
        }
        expired = true
    }
}
