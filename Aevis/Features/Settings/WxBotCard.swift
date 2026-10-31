import SwiftUI

/// 「微信官方个人 Bot」渠道卡（2026-11-01 用户要求加进 App）。
///
/// 数据源：HK 的 wx-login 服务（经 aevis.cn/wxbot 公开暴露，不走我们的业务后端）。
/// 用户拿微信扫 `qr.png` 就把自己的微信接成个人 Bot；绑定后可以在 App 里
/// **选这个人设跟 Bot 聊**（2026-11-01 用户要求：绑定时要能选人设）。
struct WxBotCard: View {
    @ObservedObject private var personaStore = PersonaStore.shared
    @State private var phase: String = ""
    @State private var accountId: String = ""
    @State private var message: String = ""
    @State private var loading = true

    /// 绑定：用户扫码连接成功后，选一个自己的人设跟这个 Bot 配对。
    @State private var selectedContactID: UUID?
    @State private var binding = false
    @State private var boundPersona: String = ""
    @State private var bindError: String = ""

    /// 当前选中的人设名（给后端存的是人设名，跨端可读）。
    private var selectedPersonaName: String {
        personaStore.contacts
            .first { $0.id == selectedContactID }?
            .persona.name ?? ""
    }

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

            Text("用你的微信扫上面的码，扫码后这台微信就成了你的个人 Bot —— 每个用户独立会话、独立记忆。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ---- 选人设 + 绑定（2026-11-01 用户要求） ----
            if phase == "connected" {
                if personaStore.contacts.isEmpty {
                    Text("先在 App 里创建一个人设，再回来绑定。")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("用哪个人设", selection: $selectedContactID) {
                        Text("选一个人设…").tag(UUID?.none)
                        ForEach(personaStore.contacts) { c in
                            Text(c.displayName).tag(UUID?.some(c.id))
                        }
                    }
                    .font(.aevis(13.5))

                    Button {
                        Task { await bind() }
                    } label: {
                        HStack {
                            if binding { ProgressView().controlSize(.small) }
                            Text(boundPersona.isEmpty ? "绑定这个人设" : "已绑定：\(boundPersona)（点此换绑）")
                                .font(.aevis(13.5, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedContactID == nil || binding)

                    if !bindError.isEmpty {
                        Text(bindError)
                            .font(.aevis(12))
                            .foregroundStyle(.red)
                    }
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.aevis(12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .task {
            await load()
            loadMyBind()
        }
        .refreshable {
            await load()
            loadMyBind()
        }
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

    /// 已有绑定先回显（换绑时能看见现在绑的是谁）。
    private func loadMyBind() {
        let account = AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else { return }
        var req = URLRequest(url: URL(string: AevisHosts.accountBase + "/v1/wxbot/my")!)
        req.setValue(account, forHTTPHeaderField: "X-Account")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any] else { return }
            DispatchQueue.main.async {
                boundPersona = d["persona"] as? String ?? ""
            }
        }.resume()
    }

    private func bind() async {
        guard let contact = personaStore.contacts.first(where: { $0.id == selectedContactID }) else { return }
        binding = true
        bindError = ""
        defer { binding = false }

        let account = AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else {
            bindError = "先登录账号再绑定"
            return
        }

        var req = URLRequest(url: URL(string: AevisHosts.accountBase + "/v1/wxbot/bind")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(account, forHTTPHeaderField: "X-Account")
        let body: [String: String] = [
            "bot_account": accountId.isEmpty ? "default" : accountId,
            "persona": contact.persona.name,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if (obj["code"] as? Int) == 0 {
                boundPersona = contact.persona.name
            } else {
                bindError = (obj["msg"] as? String) ?? "绑定失败"
            }
        } catch {
            bindError = "网络异常：\(error.localizedDescription)"
        }
    }
}
