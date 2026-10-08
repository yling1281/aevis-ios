import SwiftUI

/// 首次打开 / 退出登录后：填服务器地址 + 账号 + 密码。
///
/// 这就是**电脑上那个后台的同一个账号**（`/admin` 用的也是它），
/// 所以不用再去后台单独生成什么密钥 —— 管理员账号直接登。
///
/// ⚠️ 登录成功后只把**令牌**存本机；密码不落盘。
struct LoginView: View {
    @ObservedObject private var cfg = AppConfig.shared

    @State private var server = AppConfig.shared.server
    @State private var user = AppConfig.shared.username
    @State private var pass = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("零砚后台").font(.title3.weight(.semibold))
                        Text("用管理员账号登录，和电脑上的后台是同一个")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                // ⚠️ 不能写成 Section("服务器地址") { … } footer: { … } ——
                //    SwiftUI **没有** init(_:content:footer:)，带了 footer 就必须用
                //    Section { } header: { Text(…) } footer: { … }（编译错误极具迷惑性）。
                Section {
                    TextField(AppConfig.defaultServer, text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.callout)
                    Button("主地址 \(AppConfig.defaultServer)") {
                        server = AppConfig.defaultServer
                    }
                    .font(.footnote)
                    Button("备用地址 \(AppConfig.backupServer)") {
                        server = AppConfig.backupServer
                    }
                    .font(.footnote)
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("一般情况下不用改。主地址连不上时，点一下「备用地址」再登录。")
                        .font(.caption2)
                }

                Section {
                    TextField("管理员账号", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.callout)
                    SecureField("密码", text: $pass)
                        .font(.callout)
                } header: {
                    Text("账号")
                } footer: {
                    Text("跟电脑上登 \(AppConfig.defaultServer)/admin 用的是同一个账号密码。")
                        .font(.caption2)
                }

                if !msg.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: msgOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(msgOK ? .green : .red)
                            Text(msg).font(.footnote)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await doLogin() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "正在登录…" : "登录").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || user.trimmingCharacters(in: .whitespaces).isEmpty
                              || pass.isEmpty)
                }
            }
            .navigationTitle("登录后台")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func doLogin() async {
        busy = true
        msg = ""
        do {
            let r = try await API.shared.login(server: server, username: user, password: pass)
            let tok = r.s("token")
            guard !tok.isEmpty else {
                msgOK = false
                msg = "服务器没返回登录令牌"
                busy = false
                return
            }
            let isOwner = r.b("is_owner")
            let isAdmin = r.b("is_admin")
            guard isAdmin || isOwner else {
                msgOK = false
                msg = "「\(r.s("user"))」不是管理员账号，进不了后台。要用管理员账号登录。"
                busy = false
                return
            }
            let role = isOwner ? "站长" : "管理员"
            AppConfig.shared.save(server: server, user: r.s("user"), token: tok, role: role)
            msgOK = true
            msg = "登录成功：\(r.s("user"))（\(role)）"
            pass = ""
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
