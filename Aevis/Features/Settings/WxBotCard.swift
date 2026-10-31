import SwiftUI

/// 「微信官方个人 Bot」渠道卡（2026-11-01 用户要求加进 App）。
///
/// 数据源：HK 的 wx-login 服务（经 aevis.cn/wxbot 公开暴露，不走我们的业务后端）。
/// 用户拿微信扫 `qr.png` 就把自己的微信接成个人 Bot —— 每个用户独立会话、独立记忆。
struct WxBotCard: View {
    @State private var phase: String = ""
    @State private var accountId: String = ""
    @State private var message: String = ""
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("微信个人 Bot")
                    .font(.aevis(15.5, weight: .medium))
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else if phase == "connected" {
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .font(.aevis(12.5))
                        .foregroundStyle(.green)
                } else {
                    Text(phase.isEmpty ? "未知" : phase)
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
            }

            if !accountId.isEmpty {
                Text("Bot 账号：\(accountId)")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            }

            // 登录二维码：微信扫一扫 → 把这台微信接进 Bot
            AsyncImage(url: URL(string: "https://aevis.cn/wxbot/qr.png")) { img in
                img.resizable().interpolation(.none)
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                    if loading {
                        ProgressView()
                    } else {
                        Text("二维码加载失败\n下拉重试")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(width: 190, height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity)

            Text("用你的微信扫上面的码，扫码后这台微信就成了你的个人 Bot —— 每个用户独立会话、独立记忆，聊天内容互不串。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !message.isEmpty {
                Text(message)
                    .font(.aevis(12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(
                from: URL(string: "https://aevis.cn/wxbot/status")!)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            phase = obj["phase"] as? String ?? ""
            accountId = obj["accountId"] as? String ?? ""
            message = obj["message"] as? String ?? ""
        } catch {
            phase = ""
        }
    }
}
