import SwiftUI

/// 「微信官方个人 Bot」渠道卡（2026-11-01 用户要求加进 App）。
///
/// 数据源：HK 的 wx-login 服务（经 aevis.cn/wxbot 公开暴露，不走我们的业务后端）。
/// 用户拿微信扫 `qr.png` 就把自己的微信接成个人 Bot；绑定后可以在 App 里
/// **选这个人设跟 Bot 聊**（2026-11-01 用户要求：绑定时要能选人设）。
struct WxBotCard: View {
    @ObservedObject private var personaStore = PersonaStore.shared
    @State private var phase: String = ""
    /// 二维码地址。**必须带时间戳**：图片是服务端每次现画的，
    /// 但 AsyncImage 会缓存同一个 URL —— 不换 URL 就会一直是旧码
    ///（用户 2026-11-01：「二维码居然是固定的」）。
    @State private var qrURL: URL?
    @State private var refreshing = false
    @State private var accountId: String = ""
    @State private var message: String = ""
    @State private var loading = true

    /// 绑定：用户扫码连接成功后，选一个自己的人设跟这个 Bot 配对。
    @State private var selectedContactID: UUID?
    @State private var binding = false
    @State private var boundPersona: String = ""
    @State private var bindError: String = ""
    /// 绑定成功的那一条（用户要求「绑定成功的话记得写一个绑定成功」）。
    @State private var bindOK = false
    /// 对话余额 —— 绑定的人设用的是这个账号的积分，绑的时候一并显示。
    @State private var balance: Int?

    /// 当前选中的人设名（给后端存的是人设名，跨端可读）。
    private var selectedPersonaName: String {
        personaStore.contacts
            .first { $0.id == selectedContactID }?
            .persona.name ?? ""
    }

    private var accountLabel: String {
        let e = AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? "（未登录）" : e
    }

    private var balanceText: String {
        guard let b = balance else { return "" }
        return "，余 \(b) 积分"
    }

    private var bindButtonTitle: String {
        if boundPersona.isEmpty { return "绑定这个人设" }
        if let n = personaStore.contacts.first(where: { $0.id == selectedContactID })?.persona.name,
           n == boundPersona {
            return "已绑定：\(n)"
        }
        return "换绑成这个人设"
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
            AsyncImage(url: qrURL) { img in
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

            Button {
                Task { await refreshQR() }
            } label: {
                HStack(spacing: 6) {
                    if refreshing { ProgressView().controlSize(.small) }
                    Text(refreshing ? "正在刷新…" : "刷新二维码")
                        .font(.aevis(13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
            .buttonStyle(.bordered)
            .disabled(refreshing)

            Text("用你的微信扫上面的码，扫码后这台微信就成了你的个人 Bot —— 每个用户独立会话、独立记忆。码会过期，扫不出来就点上面刷新。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ---- 选人设 + 绑定（2026-11-01 用户要求） ----
            //
            // 🔴 2026-11-01 修「微信个人 Bot 绑不了人设」：
            //    原来这一整块写在 `if phase == "connected"` 里面 ——
            //    Bot 一旦没连上（服务重启、码过期、隧道抖一下），**人设选择器整个消失**，
            //    用户看到的就是「绑不了人设」，连按钮都没有。
            //    现在：选择器始终在（只要 App 里有人设），
            //    只有未连接时才在按钮上提示「先扫码连上」。
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
                        Text(bindButtonTitle)
                            .font(.aevis(13.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedContactID == nil || binding)

                // 绑定成功：绿色一条，写明「人设 + 余额跟着哪个账号走」。
                // 用户 2026-11-01：「绑定成功的话记得在这里面写一个绑定成功」。
                if bindOK {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("绑定成功：\(boundPersona)", systemImage: "checkmark.circle.fill")
                            .font(.aevis(12.5, weight: .medium))
                            .foregroundStyle(.green)
                        Text("对话余额已绑定到账号 \(accountLabel)\(balanceText)")
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.green.opacity(0.10))
                    )
                } else if !boundPersona.isEmpty {
                    Text("当前绑定：\(boundPersona)")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }

                if !bindError.isEmpty {
                    Text(bindError)
                        .font(.aevis(12))
                        .foregroundStyle(.red)
                }

                // 余额不够是会真的挡住对话的，所以提前把话说明白。
                Text("\(Pronoun.current)在微信里每聊一句都从你的积分里扣；积分不够时会直接回你一句「积分不够」。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
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
            await loadBalance()
            // 每 5 秒看一次状态 —— 用户扫完不用手动刷新，界面自己变「已连接」。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                if phase == "connected" { continue }
                await load()
            }
        }
        .refreshable {
            await load()
            loadMyBind()
        }
    }

    private func load() async {
        loading = qrURL == nil
        defer { loading = false }
        // 走业务后端：它会拼好 `?t=<毫秒>`，天然绕开缓存
        guard let url = URL(string: AevisHosts.accountBase + "/v1/wxbot/qr"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            phase = "unknown"
            return
        }
        phase = d["phase"] as? String ?? ""
        accountId = d["accountId"] as? String ?? ""
        message = d["message"] as? String ?? ""
        if let q = d["qr"] as? String { qrURL = URL(string: q) }
    }

    /// 刷新二维码：让服务端重开登录流程，出一张全新的码。
    private func refreshQR() async {
        refreshing = true
        defer { refreshing = false }
        guard let url = URL(string: AevisHosts.accountBase + "/v1/wxbot/refresh") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else {
            message = "刷新失败，稍后再试"
            return
        }
        phase = d["phase"] as? String ?? phase
        if let q = d["qr"] as? String { qrURL = URL(string: q) }
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
        guard let contact = personaStore.contacts.first(where: { $0.id == selectedContactID }) else {
            // 原来这里直接 return —— 选了人但匹配不上时按钮**一点反应都没有**，
            // 看着就像「绑不了」。现在至少给一句话。
            bindError = "没找到选中的这个人设，换一个再试"
            return
        }
        binding = true
        bindError = ""
        bindOK = false
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
        // ⚠️ `bot_account` 不能拿空的 accountId 硬填 —— 未连接时它本来就是空的。
        //    这里统一用绑定账号本身做 key，服务端按「一个微信用户一份绑定」记，
        //    余额也就跟着这个账号走（用户 2026-11-01：「每个的余额记得也要绑定」）。
        let body: [String: String] = [
            "bot_account": accountId.isEmpty ? account : accountId,
            "persona": contact.persona.name,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if (obj["code"] as? Int) == 0 {
                boundPersona = contact.persona.name
                bindOK = true
                await loadBalance()
            } else {
                bindError = (obj["msg"] as? String) ?? "绑定失败"
            }
        } catch {
            bindError = "网络异常：\(error.localizedDescription)"
        }
    }

    /// 拉一次积分余额（对话扣的就是它）。走 Bearer，不走 X-Account。
    private func loadBalance() async {
        let token = AppSettings.shared.accountToken
        guard !token.isEmpty,
              let url = URL(string: AevisHosts.accountBase + "/v1/points") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { return }
        if let p = d["points"] as? Int {
            balance = p
        }
    }
}
