import SwiftUI

/// 首次打开 / 退出登录后：登**码支付后台**。
///
/// 用的就是电脑上登 `…/payadmin/` 的同一个账号密码（默认 `admin`）。
/// 登录成功后服务端会把令牌同时放进响应体（`token`），我们存本机、
/// 之后每个请求带 `X-Pay-Token` 请求头 —— 不走 Cookie，理由见 PayAPI 顶部注释。
struct PayLoginView: View {
    @ObservedObject private var cfg = PayConfig.shared

    @State private var server = PayConfig.shared.server
    @State private var user = PayConfig.shared.username
    @State private var pass = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("码支付后台").font(.title3.weight(.semibold))
                        Text("用电脑上登 /payadmin/ 的那个账号登录")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                // ⚠️ 带 footer 时必须写成 Section { } header: { Text(…) } footer: { … } ——
                //    SwiftUI **没有** init(_:content:footer:)（素材后台那边为这个挂过一轮）。
                Section {
                    TextField(PayConfig.defaultServer, text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.callout)
                    Button("主地址 \(PayConfig.defaultServer)") {
                        server = PayConfig.defaultServer
                    }
                    .font(.footnote)
                    Button("备用地址 \(PayConfig.backupServer)") {
                        server = PayConfig.backupServer
                    }
                    .font(.footnote)
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("默认这条就带着 /payadmin 路径，**别去掉** —— 去掉会打到素材后端上去。"
                         + "只填域名的话 App 会自己补上。")
                        .font(.caption2)
                }

                Section {
                    TextField("后台账号", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .font(.callout)
                    SecureField("密码", text: $pass)
                        .font(.callout)
                } header: {
                    Text("账号")
                } footer: {
                    Text("登录成功后只把令牌存在这台手机上，密码不落盘。")
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
                    .disabled(busy || user.trimmingCharacters(in: .whitespaces).isEmpty || pass.isEmpty)
                }
            }
            .navigationTitle("登录码支付后台")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func doLogin() async {
        busy = true
        msg = ""
        do {
            let r = try await PayAPI.shared.login(server: server, username: user, password: pass)
            let tok = r.s("token")
            guard !tok.isEmpty else {
                msgOK = false
                msg = "服务器没返回登录令牌（服务端是不是旧版？）"
                busy = false
                return
            }
            PayConfig.shared.save(server: server, user: r.s("username"), token: tok)
            msgOK = true
            msg = "登录成功：\(r.s("username"))（\(r.s("role"))）"
            pass = ""
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
