import SwiftUI

/// 首次打开：填服务器地址 + API Key。
///
/// Key 在 **管理后台 → 对外 API** 里创建（`https://lingyan.cyou:8642/admin`），
/// 创建时只显示一次明文，所以这里让用户直接粘进来。
struct SetupView: View {
    @ObservedObject private var cfg = AppConfig.shared

    @State private var server = AppConfig.shared.server
    @State private var key = AppConfig.shared.apiKey
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
                        Text("填上服务器地址和 API Key 就能看数据（只看不改）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section("服务器地址") {
                    TextField(AppConfig.defaultServer, text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.callout)
                    Button("填主地址 \(AppConfig.defaultServer)") {
                        server = AppConfig.defaultServer
                    }
                    .font(.footnote)
                    Button("填备用地址 \(AppConfig.backupServer)") {
                        server = AppConfig.backupServer
                    }
                    .font(.footnote)
                }

                Section {
                    SecureField("LYAPI-…", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                } header: {
                    Text("API Key")
                } footer: {
                    Text("在电脑上打开 \(AppConfig.defaultServer)/admin → 左侧「对外 API」→ 新建，把生成的那串（LYAPI-…）粘到上面。Key 只存在这台手机上。")
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
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "正在连接…" : "连接并进入").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("连接后台")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func connect() async {
        busy = true
        msg = ""
        AppConfig.shared.save(server: server, key: key)      // 先存，API 读的是它
        do {
            let me = try await API.shared.get("/api/v1/me")
            let scopes = me.strings("scopes").joined(separator: " / ")
            msgOK = true
            msg = "连接成功：\(me.s("name"))（权限：\(scopes.isEmpty ? "—" : scopes)）"
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
