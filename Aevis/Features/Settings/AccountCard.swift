import SwiftUI

/// 「账号」设置卡。
///
/// 用户说「到时候会拿新的服务器跟你对接」—— 所以这一页现在只做两件事：
/// **填服务器地址**、**注册 / 登录**。
/// 地址留空就整块是「未连接」，App 别的功能一样都不少（这是本地 App）。
///
/// 密码**不落盘**：填完当场用掉，成功只留 token（进钥匙串）。
struct AccountCard: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var account = AccountService.shared

    @State private var showForm = false
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var note: String?
    @State private var busy = false
    @State private var probing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("账号")

            serverRow
            rule
            statusRow
            rule
            actionRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let error = account.lastError, !error.isEmpty {
                rule
                Text(error)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            Text("服务器地址已经内嵌在 App 里，不用你填。这个账号是可选的："
                 + "人设、聊天记录、记忆本来都只存在这台手机上。\n"
                 + "密码只在你点「登录 / 注册」的那一下用，不会被存下来。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(isPresented: $showForm) {
            formSheet
        }
    }

    // MARK: - 各行

    private var serverRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("服务器")
                    .font(.aevis(15))
                Text(lineText)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(probing ? "探测中…" : "换线") {
                Task { await reprobe() }
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
            .disabled(probing)
        }
    }

    /// 「线路一 · account.apekin.com」—— 让用户看得出现在走的是哪条线。
    /// 域名会被云厂商按**线路抽样**拦，所以两条线互为备用，全自动切换。
    private var lineText: String {
        let pretty = settings.accountServerURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        if pretty.isEmpty { return "没配" }
        guard let line = AevisHosts.lineName(for: settings.accountServerURL) else {
            return pretty
        }
        return line + " · " + pretty
    }

    /// 手动重新探测线路（启动时已经自动探过一次，这里给用户一个"我手动试一下"的入口）。
    private func reprobe() async {
        probing = true
        defer { probing = false }
        let base = await AccountEndpoint.refresh()
        settings.accountServerURL = base
        if let line = AevisHosts.lineName(for: base) {
            note = "已切到\(line)。"
        } else {
            note = "两条线路都连不上，稍后再试。"
        }
    }

    private var statusRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("状态")
                    .font(.aevis(15))
                Text(account.statusLine)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if account.isSignedIn {
                Button("刷新资料") {
                    Task { await account.refreshProfile() }
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
    }

    private var actionRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.isSignedIn ? "退出登录" : "登录 / 注册")
                    .font(.aevis(15))
                Text(account.isSignedIn
                     ? "只清掉本机的登录状态，别的都不动"
                     : "在系统浏览器里收个验证码就行，不用记密码")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if account.isSignedIn {
                Button("退出") {
                    account.signOut()
                    note = "已退出。"
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            } else {
                Button(busy ? "打开中…" : "用邮箱登录") {
                    startWebLogin()
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
    }

    // MARK: - 网页登录
    //
    // 账号后端是**邮箱验证码**（没有密码），所以这里不再自己画用户名/密码框 ——
    // 把官网登录页交给**系统浏览器**：用户在那个页面收码登录（第一次用就在同一页
    // 拿注册码注册），完事页面跳 `aevis://login?token=...`，我们收下。
    //
    // ⚠️ 回调是 `aevis://login`，这是服务端 `api_verify` 里拼的
    //（`app_url = aevis://login?token=<token>`）。改服务端要同步这里。
    private func startWebLogin() {
        guard let url = account.webLoginURL() else {
            note = "登录页地址拼不出来，检查一下服务器地址。"
            return
        }
        busy = true
        note = nil
        Task { @MainActor in
            let callback = await WebAuth.shared.run(url: url, scheme: "aevis")
            busy = false
            guard let callback else {
                note = "登录取消了。"
                return
            }
            guard let token = Self.token(from: callback) else {
                note = "登录回来了，但没带凭证。回调是：\(callback.absoluteString.prefix(70))"
                return
            }
            do {
                try await account.adoptWebToken(token)
                note = "登录好了。"
            } catch {
                note = "没登成：" + error.localizedDescription
            }
        }
    }

    /// 从 `aevis://login?token=xxxx` 里把 token 抠出来。
    private static func token(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "token" })?
            .value
    }

    // MARK: - 注册 / 登录表单

    private var formSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("用户名", text: $username, secret: false)
                    field("密码", text: $password, secret: true)
                    field("昵称（可以不填）", text: $nickname, secret: false)

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            submit(register: true)
                        } label: {
                            Text("注册")
                                .font(.aevis(14, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .aevisGlass(cornerRadius: 14)
                        }
                        .disabled(busy || !canSubmit)

                        Button {
                            submit(register: false)
                        } label: {
                            Text("登录")
                                .font(.aevis(14, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .aevisGlass(cornerRadius: 14)
                        }
                        .disabled(busy || !canSubmit)

                        if busy { ProgressView().controlSize(.small) }

                        Spacer(minLength: 0)
                    }

                    Text("密码只在这一下用掉，不会被保存；成功后只存服务器给的 token（在钥匙串里）。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .navigationTitle("登录 / 注册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showForm = false }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            if secret {
                SecureField("", text: text)
                    .textContentType(.password)
                    .font(.aevis(15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            } else {
                TextField("", text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.aevis(15))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
    }

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private func submit(register: Bool) {
        busy = true
        note = nil
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        let nick = nickname.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            defer { busy = false }
            do {
                if register {
                    try await account.register(username: user, password: pass, nickname: nick)
                    note = "注册好了，已经登录。"
                } else {
                    try await account.signIn(username: user, password: pass)
                    note = "登录成功。"
                }
                // 密码用完就丢，别留在内存里
                password = ""
                showForm = false
            } catch {
                note = error.localizedDescription
            }
        }
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
