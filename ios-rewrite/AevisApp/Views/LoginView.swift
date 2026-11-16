import SwiftUI

/// 登录 + 恢复码（2026-11-17，134 骨架）。
struct LoginView: View {
    @EnvironmentObject private var session: Session
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error = ""

    @State private var showRecover = false
    @State private var code = ""
    @State private var recoverMsg = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("Aevis").font(.system(size: 34, weight: .semibold))
                Text("登录你的账号").font(.footnote).foregroundStyle(.secondary)

                TextField("邮箱", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)

                if !error.isEmpty {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await doLogin() }
                } label: {
                    Text(busy ? "登录中…" : "登录")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || email.isEmpty || password.isEmpty)

                Button("用恢复码找回聊天记录") { showRecover = true }
                    .font(.footnote)

                Spacer()
            }
            .padding(24)
            .sheet(isPresented: $showRecover) { recoverSheet }
        }
    }

    private var recoverSheet: some View {
        VStack(spacing: 14) {
            Text("用恢复码恢复").font(.headline)
            TextField("8 位码，例：56TR-ZCLD", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            if !recoverMsg.isEmpty {
                Text(recoverMsg).font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await doRecover() }
            } label: {
                Text("恢复").frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Button("关闭") { showRecover = false }
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
    }

    private func doLogin() async {
        busy = true; error = ""
        do {
            let r = try await APIClient.login(email: email, password: password)
            session.save(token: r.token, email: email)
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    /// 恢复码只拉备份并存成本地会话；图片等资源后续版本再下载。
    private func doRecover() async {
        let norm = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard norm.count == 8 else {
            recoverMsg = "码要 8 位（现在 \(norm.count) 位）"
            return
        }
        do {
            let backup = try await APIClient.recover(code: norm)
            guard let data = backup.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                recoverMsg = "备份结构认不出"
                return
            }
            // 兼容两种：{convs:{…}} 与扁平 {pid:[…]}
            let convs = (root["convs"] as? [String: Any]) ?? root
            var n = 0
            for (pid, value) in convs {
                guard let rows = value as? [[String: Any]] else { continue }
                let msgs = rows.compactMap { row -> Msg? in
                    guard let content = (row["content"] as? String) ?? (row["body"] as? String) else {
                        return nil
                    }
                    var role = row["role"] as? String ?? "user"
                    if role == "ai" || role == "model" { role = "assistant" }
                    if role == "human" { role = "user" }
                    var m = Msg(role: role, content: content)
                    m.img = row["i"] as? String ?? ""
                    return m
                }
                LocalStore.save(pid: pid, msgs: msgs)
                n += 1
            }
            recoverMsg = "已恢复 \(n) 个会话（图片后续版本再拉）"
        } catch {
            recoverMsg = error.localizedDescription
        }
    }
}
