import SwiftUI
import UIKit

/// 设置：服务器地址 / 账号 / 下载去向（百度网盘）/ 下载项 / 改密码 / 退出。
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cfg = AppConfig.shared

    @State private var server = AppConfig.shared.server
    @State private var msg = ""
    @State private var msgOK = false
    @State private var busy = false

    @State private var dlRows: [[String: Any]] = []
    @State private var dlState: LoadState = .idle
    @State private var editing: String?
    @State private var dlURL = ""
    @State private var dlCode = ""
    @State private var showPw = false
    @State private var oldPw = ""
    @State private var newPw = ""
    @State private var pwMsg = ""
    @State private var pwOK = false
    @State private var confirmOut = false

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
                    Button("主地址（香港 8642）") { server = AppConfig.defaultServer }
                        .font(.footnote)
                    Button("备用地址（香港 443）") { server = AppConfig.backupServer }
                        .font(.footnote)
                    Button("保存并测连接") { Task { await ping() } }
                        .disabled(busy)
                    if !msg.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: msgOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(msgOK ? .green : .red)
                            Text(msg).font(.footnote)
                        }
                    }
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("改完地址要重新登录（令牌是服务器签的，换地址就不认了）。")
                        .font(.caption2)
                }

                Section("当前账号") {
                    KVRow(k: "账号", v: cfg.username)
                    KVRow(k: "身份", v: cfg.roleText)
                    KVRow(k: "地址", v: cfg.shortServer, mono: true)
                    Button {
                        oldPw = ""; newPw = ""; pwMsg = ""
                        showPw = true
                    } label: {
                        Label("修改我的密码", systemImage: "lock.rotation")
                    }
                    .font(.footnote)
                }

                // ---- 下载去向 ----
                Section {
                    if case .fail = dlState {
                        StateBanner(state: dlState) { Task { await loadDL() } }
                    }
                    ForEach(dlRows.indices, id: \.self) { i in
                        let r = dlRows[i]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(r.s("title")).font(.footnote.weight(.medium))
                                Chip(text: r.s("mode") == "netdisk" ? "网盘" : "服务器直链",
                                     tint: r.s("mode") == "netdisk" ? .orange : .blue)
                            }
                            Text(r.s("final").isEmpty ? r.s("legacy") : r.s("final"))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 12) {
                                Button("改链接") {
                                    editing = r.s("key")
                                    dlURL = r.s("url")
                                    dlCode = r.s("code")
                                }
                                .font(.caption)
                                Button("清空（改回直链）") {
                                    Task { await saveDL(r.s("key"), "", "") }
                                }
                                .font(.caption)
                                .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("下载去向（官网三个下载按钮指向哪）")
                } footer: {
                    Text("填了百度网盘分享链接 + 提取码，官网点下载就直接跳网盘；清空就回到服务器直链。")
                        .font(.caption2)
                }

                Section("关于") {
                    KVRow(k: "版本", v: version)
                    KVRow(k: "构建", v: commit.isEmpty ? "—" : String(commit.prefix(9)), mono: true)
                    KVRow(k: "设备", v: UIDevice.current.name)
                }

                Section {
                    Button(role: .destructive) {
                        confirmOut = true
                    } label: {
                        Text("退出登录")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .task { await loadDL() }
            .alert("下载链接", isPresented: Binding(
                get: { editing != nil },
                set: { if !$0 { editing = nil } }
            )) {
                TextField("百度网盘分享链接（https://pan.baidu.com/...）", text: $dlURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("提取码（可空）", text: $dlCode)
                Button("取消", role: .cancel) { editing = nil }
                Button("保存") {
                    let k = editing ?? ""
                    let u = dlURL
                    let c = dlCode
                    editing = nil
                    Task { await saveDL(k, u, c) }
                }
            } message: {
                Text("填了提取码会自动拼成 ?pwd=xxxx，用户点下载直接就进去了。")
            }
            .alert("修改我的密码", isPresented: $showPw) {
                SecureField("当前密码", text: $oldPw)
                SecureField("新密码（至少 6 位）", text: $newPw)
                Button("取消", role: .cancel) {}
                Button("提交") { Task { await changePw() } }
            } message: {
                Text(pwMsg.isEmpty ? "改完下次登录用新密码。" : pwMsg)
            }
            .confirmationDialog("确定退出登录？", isPresented: $confirmOut, titleVisibility: .visible) {
                Button("退出", role: .destructive) {
                    cfg.signOut()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func ping() async {
        busy = true
        msg = ""
        let wasSame = AppConfig.normalize(server) == AppConfig.shared.baseURL
        if !wasSame {
            // 换了地址：令牌是旧服务器签的，留着也过不了，直接退出登录
            AppConfig.shared.saveServer(server)
            cfg.signOut()
            busy = false
            dismiss()
            return
        }
        AppConfig.shared.saveServer(server)
        if AppConfig.isDemo {
            msgOK = true; msg = "演示模式（不连服务器）"
            busy = false
            return
        }
        do {
            let r = try await API.shared.get("/api/auth/me")
            msgOK = true
            msg = "连接正常：\(r.s("user"))（\(cfg.roleText)）"
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }

    private func loadDL() async {
        if AppConfig.isDemo {
            dlRows = DemoData.dlConfig
            dlState = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/pub/dl-config")
            dlRows = r.list("items")
            dlState = .done
        } catch {
            dlState = .fail((error as? APIError)?.message ?? error.localizedDescription,
                            (error as? APIError)?.status ?? 0)
        }
    }

    private func saveDL(_ key: String, _ url: String, _ code: String) async {
        if key.isEmpty { return }
        if AppConfig.isDemo {
            Toast.shared.show("演示模式：没有真的改")
            return
        }
        do {
            let r = try await API.shared.put("/api/pub/dl-config", body: [
                "items": [key: ["url": url, "code": code]],
            ])
            dlRows = r.list("items")
            Toast.shared.show(url.isEmpty ? "已改回服务器直链" : "已保存")
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
    }

    private func changePw() async {
        if AppConfig.isDemo {
            pwMsg = "演示模式：没有真的改"
            return
        }
        do {
            _ = try await API.shared.post("/api/auth/change-password",
                                          body: ["old_password": oldPw, "new_password": newPw])
            pwMsg = "密码已改，下次登录用新密码"
            Toast.shared.show("密码已修改")
        } catch {
            pwMsg = (error as? APIError)?.message ?? error.localizedDescription
            Toast.shared.show(pwMsg)
        }
    }
}
