import SwiftUI
import UIKit

/// QQ 机器人：那把发码钥匙，以及最近谁领过码。
///
/// ⚠️ 钥匙只给服务器用 —— 谁拿到就能绕过机器人直接调接口发码。
/// 所以这一页的东西**别截图发出去**。
struct BotSection: View {
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "发码钥匙")
            AdminCard {
                if let info = store.bot {
                    VStack(alignment: .leading, spacing: 10) {
                        if let key = info.key, !key.isEmpty {
                            Text(key)
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                AdminCopyButton(text: key, label: "复制钥匙")
                            }
                        } else {
                            Text("服务器上还没生成这把钥匙。重新部署一次后端就会有了。")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("最近 24 小时发出的领取口令")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(info.tickets24h ?? 0))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                        }
                    }
                    .padding(14)
                } else {
                    AdminEmpty(text: store.loading ? "读取中…" : "没拿到数据。")
                }
            }
            AdminNote(text: "机器人现在跑在服务器上（`aevis-qqbot` 服务），不用 App 配合。"
                     + "钥匙一旦泄漏，重新部署后端就会换一把新的 —— 旧的那把立刻失效。")

            AdminSectionTitle(text: "最近领过码的人")
            if let claims = store.bot?.claims, !claims.isEmpty {
                AdminCard {
                    ForEach(Array(claims.enumerated()), id: \.element.id) { index, claim in
                        AdminCardRow(showsDivider: index > 0) {
                            AdminLine(
                                title: claim.code ?? "—",
                                subtitle: "群成员 \(claim.member ?? "—")…　·　群 \(claim.group ?? "—")…",
                                detail: AdminFormat.when(claim.at) + "（\(AdminFormat.ago(claim.at))）"
                            )
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
                AdminNote(text: "这是**官方机器人**那条路（群里 @ 它换口令）。"
                         + "协议号「自助注册」发出去的码在「账号」那边的注册码列表里也能看到。")
            } else {
                AdminCard { AdminEmpty(text: "还没有人领过。") }
            }
        }
    }
}

/// 后台自己的账号密码。
///
/// 设好之后就能用账号密码登录 —— 手机上填一次就一直用，
/// 不用每次都去收邮件抄验证码。**邮箱验证码那条路一直留着**：
/// 忘了密码、或者怀疑密码泄漏了，就用它进来改。
struct AccountSection: View {
    @EnvironmentObject private var store: AdminStore

    @State private var username = ""
    @State private var password = ""
    @State private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "当前登录")
            AdminCard {
                AdminCardRow {
                    AdminLine(
                        title: store.signedInEmail.isEmpty ? "（未知）" : store.signedInEmail,
                        subtitle: "服务器 \(store.base)",
                        detail: store.accountInfo?.updatedAt.map {
                            "账号密码上次改动 \(AdminFormat.when($0))"
                        }
                    )
                }
            }

            AdminSectionTitle(text: "设后台账号密码")
            AdminCard {
                VStack(alignment: .leading, spacing: 11) {
                    TextField("用户名（3–32 字）", text: $username)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    SecureField("新密码（至少 8 位）", text: $password)
                        .font(.system(size: 14))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    Button {
                        let name = username.trimmingCharacters(in: .whitespaces)
                        let pass = password
                        Task {
                            if await store.saveAdminAccount(username: name, password: pass) {
                                password = ""
                            }
                        }
                    } label: {
                        Text(store.busy ? "保存中…" : "保存")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(canSave ? AdminSkin.brand : Color.gray.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave || store.busy)
                }
                .padding(14)
            }
            AdminNote(text: "密码按 PBKDF2 存盐哈希，服务器上不存明文；连错 5 次锁 15 分钟。"
                     + "换个用户名或密码不会把已登录的会话踢掉，但建议改完用新的登一次确认能进。")

            AdminSectionTitle(text: "别忘了")
            AdminCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("· 网页后台：\(store.base)/admin")
                    Text("· 服务器上的控制台密码还是初始那个，没改过的话尽快改掉")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .padding(14)
            }
        }
        .onAppear {
            // 用户名只在第一次进来时填一次 —— 否则会盖掉正在输入的内容。
            guard !loadedOnce else { return }
            loadedOnce = true
            username = store.accountInfo?.username ?? ""
        }
        .onChange(of: store.accountInfo?.username) { _, fresh in
            guard let fresh, !fresh.isEmpty, username.isEmpty else { return }
            username = fresh
        }
    }

    private var canSave: Bool {
        username.trimmingCharacters(in: .whitespaces).count >= 3 && password.count >= 8
    }
}
