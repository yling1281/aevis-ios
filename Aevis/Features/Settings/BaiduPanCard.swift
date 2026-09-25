import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「百度网盘」设置卡。
///
/// 三步：填应用凭据 → 去授权 → 把授权码贴回来。
///
/// 为什么必须这么绕：**App 拿不到"用户的网盘"**。百度只认开发者应用出面
/// 走一次 OAuth —— 用户点「同意」，百度给一个 code，用 code 换长期通行证。
/// 这不是我们偷懒，是百度网盘的规矩。
///
/// 回调地址那一栏：后台登记成 `oob` 最省事（百度页面直接把授权码显示出来）。
/// 登记成内网地址也能用 —— 页面打不开不要紧，**地址栏里带着 `?code=xxx`**，
/// 整条粘进来就行，`BaiduPanClient.cleanCode` 会把它洗干净。
struct BaiduPanCard: View {

    @ObservedObject private var settings = AppSettings.shared

    @State private var showCredentials = false
    @State private var appKeyDraft = ""
    @State private var secretDraft = ""
    @State private var showCode = false
    @State private var codeDraft = ""
    @State private var showRedirect = false
    @State private var redirectDraft = ""
    @State private var note: String?
    @State private var busy = false

    // 「搬家」那两行用的
    @State private var backups: [PanFile] = []
    @State private var showBackups = false
    @State private var picked: PanFile?
    @State private var showRestoreConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("百度网盘")

            credentialsRow

            rule

            authorizeRow

            rule

            redirectRow

            rule

            backupRow

            rule

            restoreRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if !settings.baiduPanLastError.isEmpty {
                rule
                Text(settings.baiduPanLastError)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .aevisGlass(cornerRadius: 20)
        .alert("百度网盘应用凭据", isPresented: $showCredentials) {
            TextField("AppKey", text: $appKeyDraft)
            TextField("SecretKey", text: $secretDraft)
            Button("保存") {
                settings.baiduPanAppKey = appKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                // SecretKey 留空表示不改，避免每次都要重新粘一遍
                let secret = secretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !secret.isEmpty { settings.baiduPanSecretKey = secret }
                settings.baiduPanLastError = ""
                note = BaiduPanClient.shared.isConfigured
                    ? "凭据存好了（在钥匙串里，不会外传）。下一步点「去授权」。"
                    : "AppKey 或 SecretKey 是空的，两个都要填。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在百度网盘开放平台 → 控制台 → 我的应用 → 应用详情里复制。SecretKey 只存本机钥匙串。")
        }
        .alert("粘贴授权码", isPresented: $showCode) {
            TextField("授权码，或整条回调网址", text: $codeDraft)
            Button("完成") { finishAuthorize() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("百度页面上显示的那串，或者页面上方地址栏里 code= 后面那段。整条网址粘进来也能认。")
        }
        .alert("回调地址", isPresented: $showRedirect) {
            TextField("oob", text: $redirectDraft)
            Button("保存") {
                settings.baiduPanRedirect = redirectDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = "回调地址记下了。它必须和你应用后台「安全设置」里那一栏完全一致，否则百度会报 redirect_uri 不合法。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空按 oob 走。如果后台填的是内网地址，就照抄那个地址。")
        }
        .sheet(isPresented: $showBackups) {
            backupList
        }
        .confirmationDialog(
            "恢复这份备份？",
            isPresented: $showRestoreConfirm,
            titleVisibility: .visible
        ) {
            Button("覆盖恢复", role: .destructive) { runRestore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会用备份里的内容覆盖本机现在的联系人、聊天记录、记忆和朋友圈。这一步不能撤销。")
        }
    }

    // MARK: - 三行

    private var credentialsRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("应用凭据")
                    .font(.aevis(15))
                Text(BaiduPanClient.shared.isConfigured
                     ? "已填（SecretKey 存在钥匙串，不会外传）"
                     : "还没填。需要开放平台的 AppKey 和 SecretKey")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(BaiduPanClient.shared.isConfigured ? "修改" : "去填") {
                appKeyDraft = settings.baiduPanAppKey
                secretDraft = ""
                showCredentials = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var authorizeRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.aevis(15))
                Text(statusDetail)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)

            if BaiduPanClient.shared.isAuthorized {
                Button("取消授权") {
                    BaiduPanClient.shared.signOut()
                    note = "已取消授权。"
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            } else {
                // 两个按钮分开摆：授权要跳到浏览器，回来再粘贴 ——
                // 合成一个按钮的话，用户切回来就不知道该点哪儿了。
                VStack(alignment: .trailing, spacing: 7) {
                    Button("去授权") { startAuthorize() }
                        .font(.aevis(14))
                        .buttonStyle(.borderless)
                        .disabled(!BaiduPanClient.shared.isConfigured || busy)

                    Button("粘贴授权码") { showCode = true }
                        .font(.aevis(14))
                        .buttonStyle(.borderless)
                        .disabled(!BaiduPanClient.shared.isConfigured || busy)
                }
            }
        }
    }

    private var redirectRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("回调地址")
                    .font(.aevis(15))
                Text("当前：" + (settings.baiduPanRedirect.isEmpty ? "oob（授权码显示在页面上）" : settings.baiduPanRedirect))
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("改") {
                redirectDraft = settings.baiduPanRedirect
                showRedirect = true
            }
            .font(.aevis(14))
            .buttonStyle(.borderless)
        }
    }

    private var statusTitle: String {
        if !BaiduPanClient.shared.isConfigured { return "还没配置" }
        return BaiduPanClient.shared.isAuthorized ? "已授权" : "还没授权"
    }

    private var statusDetail: String {
        if !BaiduPanClient.shared.isConfigured {
            return "填了 AppKey 和 SecretKey 才能授权"
        }
        guard BaiduPanClient.shared.isAuthorized else {
            return "点「去授权」→ 浏览器里登录并同意 → 回来说授权码"
        }
        if let expires = BaiduPanClient.shared.expiresAt {
            return "通行证有效到 " + expires.formatted(date: .abbreviated, time: .shortened)
                + "，到期会自动续，不用重新授权"
        }
        return "通行证已存好"
    }

    // MARK: - 搬家（备份 / 恢复）

    private var backupRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("备份到网盘")
                    .font(.aevis(15))
                Text(BackupService.shared.lastBackupName.isEmpty
                     ? "把联系人、聊天记录、记忆、朋友圈打成一个包传上去"
                     : "上次：\(BackupService.shared.lastBackupName)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("备份") { runBackup() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(!BaiduPanClient.shared.isAuthorized || busy)
        }
    }

    private var restoreRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("从网盘恢复")
                    .font(.aevis(15))
                Text("换手机、重装之后，把网盘上那份拉回来")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("选一份") { loadBackups() }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(!BaiduPanClient.shared.isAuthorized || busy)
        }
    }

    private var backupList: some View {
        NavigationStack {
            List {
                ForEach(backups) { file in
                    Button {
                        picked = file
                        showBackups = false
                        showRestoreConfirm = true
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.name)
                                .font(.aevis(15))
                                .foregroundStyle(.primary)
                            Text(file.detail)
                                .font(.aevis(12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if backups.isEmpty {
                    Text("网盘里还没有备份")
                        .font(.aevis(14))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("选一份备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { showBackups = false }
                }
            }
        }
    }

    private func loadBackups() {
        busy = true
        note = "正在看网盘上有哪些备份…"
        Task { @MainActor in
            defer { self.busy = false }
            do {
                backups = try await BackupService.shared.listBackups()
                if backups.isEmpty {
                    note = "网盘里还没有备份。先点左边的「备份」。"
                } else {
                    note = nil
                    showBackups = true
                }
            } catch {
                note = "看不了网盘上的备份：" + error.localizedDescription
            }
        }
    }

    private func runBackup() {
        busy = true
        note = "正在打包上传…"
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let name = try await BackupService.shared.backupToPan()
                note = "备份好了：" + name
            } catch {
                note = "备份失败：" + error.localizedDescription
            }
        }
    }

    private func runRestore() {
        guard let picked else { return }
        busy = true
        note = "正在下载并恢复…"
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let summary = try await BackupService.shared.restoreFromPan(fsID: picked.id)
                note = summary + "。头像和朋友圈配图不在包里，要自己重设一次。"
            } catch {
                note = "恢复失败：" + error.localizedDescription
            }
        }
    }

    // MARK: - 授权动作

    private func startAuthorize() {
        guard let url = BaiduPanClient.shared.authorizeURL() else {
            note = "先填 AppKey 和 SecretKey。"
            return
        }
        note = "浏览器里登录并点同意之后，切回这里点「粘贴授权码」。"
        codeDraft = ""
        #if canImport(UIKit)
        UIApplication.shared.open(url) { ok in
            guard !ok else { return }
            self.note = "没能打开浏览器。检查一下网络，或者手动去百度网盘开放平台的授权页。"
        }
        #endif
    }

    private func finishAuthorize() {
        let raw = codeDraft
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note = "没填授权码。"
            return
        }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                try await BaiduPanClient.shared.exchange(code: raw)
                self.note = "授权成功，通行证已经存进钥匙串。"
            } catch {
                self.note = "授权失败：" + error.localizedDescription
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
