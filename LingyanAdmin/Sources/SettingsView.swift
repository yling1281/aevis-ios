import SwiftUI
import UIKit

/// 设置：改服务器地址 / 换 API Key / 测连接 / 退出。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cfg = AppConfig.shared

    @State private var server = AppConfig.shared.server
    @State private var key = AppConfig.shared.apiKey
    @State private var msg = ""
    @State private var msgOK = false
    @State private var busy = false
    @State private var me: [String: Any] = [:]

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private var commit: String {
        (Bundle.main.infoDictionary?["LingyanCommit"] as? String) ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AppConfig.defaultServer, text: $server)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.callout)
                    Button("主地址") { server = AppConfig.defaultServer }.font(.footnote)
                    Button("备用地址（裸 IP）") { server = AppConfig.backupServer }.font(.footnote)
                } header: {
                    Text("服务器地址")
                }

                Section("API Key") {
                    SecureField("LYAPI-…", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                    if !cfg.apiKey.isEmpty {
                        Text("当前：\(cfg.keyHint)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        cfg.save(server: server, key: key)
                        Task { await ping() }
                    } label: {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "测试中…" : "保存并测试连接")
                        }
                    }
                    .disabled(busy)

                    if !msg.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: msgOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(msgOK ? .green : .red)
                            Text(msg).font(.footnote)
                        }
                    }

                    if !me.isEmpty {
                        KVRow(k: "Key 名称", v: me.s("name"))
                        KVRow(k: "权限", v: me.strings("scopes").joined(separator: " / "))
                    }
                }

                Section("关于") {
                    KVRow(k: "版本", v: version)
                    KVRow(k: "构建", v: commit.isEmpty ? "—" : String(commit.prefix(9)), mono: true)
                    KVRow(k: "设备名", v: UIDevice.current.name)
                    Text("零砚后台是**只读**工具：查数据、查卡密、复制下载直链。改数据请用电脑上的 /admin 后台。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(role: .destructive) {
                        cfg.signOut()
                        dismiss()
                    } label: {
                        Text("清除本机 API Key")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func ping() async {
        busy = true
        msg = ""
        me = [:]
        do {
            me = try await API.shared.get("/api/v1/me")
            msgOK = true
            msg = "连接成功（\(AppConfig.shared.shortServer)）"
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
