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

    @State private var showServer = false
    @State private var serverDraft = ""
    @State private var showForm = false
    @State private var username = ""
    @State private var password = ""
    @State private var nickname = ""
    @State private var note: String?
    @State private var busy = false

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
            Text("这个功能是可选的：不填服务器地址，App 一切照常 —— "
                 + "人设、聊天记录、记忆本来都只存在这台手机上。\n"
                 + "密码只在你点「登录 / 注册」的那一下用，不会被存下来。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .aevisGlass(cornerRadius: 20)
        .alert("服务器地址", isPresented: $showServer) {
            TextField("https://api.example.com", text: $serverDraft)
            Button("保存") {
                settings.accountServerURL = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = settings.accountServerURL.isEmpty
                    ? "地址清空了，账号这块就回到「未连接」。"
                    : "记下了。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你自己那个服务器的地址。要带 http:// 或 https://。")
        }
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
                Text(settings.accountServerURL.isEmpty ? "还没填（不填也能用）" : settings.accountServerURL)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(settings.accountServerURL.isEmpty ? "去填" : "修改") {
                serverDraft = settings.accountServerURL
                showServer = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
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
                     : "有账号就登录，没有就顺手注册一个")
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
                Button("进去填") {
                    username = ""
                    password = ""
                    nickname = ""
                    showForm = true
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(!account.isConfigured)
            }
        }
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
