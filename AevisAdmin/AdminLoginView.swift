import SwiftUI
import UIKit

/// 登录页。
///
/// 走的是**后台账号密码**那条路（`POST /api/admin/login`）——
/// 服务器把它换成一个管理员邮箱的普通令牌，和验证码登录同权
/// （`require_admin` 一个字没改，见 `server/account/app.py`）。
struct AdminLoginView: View {
    @EnvironmentObject private var store: AdminStore

    @State private var username = ""
    @State private var password = ""
    @State private var editingServer = false
    @State private var serverDraft = ""
    @State private var lineNote: String?
    @FocusState private var focus: Field?

    private enum Field { case user, pass }

    private var name: String { username.trimmingCharacters(in: .whitespaces) }
    private var canSubmit: Bool { name.count >= 3 && !password.isEmpty && !store.loading }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                fields
                actionArea
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
            .padding(.top, 56)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .onAppear { serverDraft = store.base }
        .task {
            // 开屏自动挑一条通的线路（线路一 → 线路二），和主 App 同一套判断。
            // 要是用户手动选过、且那条还通着，`autoPickLine` 会原样保留，不会乱改。
            let picked = await AdminAPI.autoPickLine()
            await MainActor.run {
                store.updateBase(AdminAPI.base)
                serverDraft = store.base
                if let picked, picked != AevisHosts.lineName(for: store.base) {
                    lineNote = "已自动切到\(picked)。"
                }
            }
        }
    }

    // MARK: 标题

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AdminSkin.brand)
                .padding(18)
                .background(AdminSkin.brand.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Aevis 管理端")
                .font(.system(size: 22, weight: .bold))
            Text("看崩溃现场、发注册码、封设备")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    // MARK: 两个输入框

    private var fields: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                TextField("用户名", text: $username)
                    .font(.system(size: 16))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .user)
                    .submitLabel(.next)
                    .onSubmit { focus = .pass }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Color(uiColor: .separator).opacity(0.5))
                .frame(height: 0.5)
                .padding(.leading, 48)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                SecureField("密码", text: $password)
                    .font(.system(size: 16))
                    .textContentType(.password)
                    .focused($focus, equals: .pass)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: AdminSkin.corner, style: .continuous))
    }

    // MARK: 登录 + 服务器

    private var actionArea: some View {
        VStack(spacing: 10) {
            Button(action: submit) {
                Group {
                    if store.loading {
                        ProgressView().tint(.white)
                    } else {
                        Text("登录")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSubmit ? AdminSkin.brand : Color.gray.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            if editingServer {
                serverEditor
            } else {
                Button {
                    serverDraft = store.base
                    withAnimation(.snappy(duration: 0.2)) { editingServer = true }
                } label: {
                    Text("服务器：" + (AevisHosts.lineName(for: store.base) ?? "自定义")
                         + " · \(store.base)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var serverEditor: some View {
        VStack(spacing: 8) {
            // 线路一 / 线路二：两条线互为备用（域名会被云厂商按线路抽样拦，谁通走谁）。
            // 和主 App 用同一份 `AevisHosts.accountLines` / 同一套探测判断。
            HStack(spacing: 8) {
                ForEach(AevisHosts.accountLines) { line in
                    let active = AevisHosts.lineName(for: store.base) == line.name
                    AdminMiniButton(title: line.name,
                                    tint: active ? AdminSkin.brand : .secondary,
                                    filled: active) {
                        store.updateBase(line.base)
                        serverDraft = store.base
                        lineNote = "已切到\(line.name)。换线要重新登录。"
                    }
                }
                Spacer(minLength: 0)
            }

            TextField(AevisHosts.accountBase, text: $serverDraft)
                .font(.system(size: 13.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack(spacing: 8) {
                AdminMiniButton(title: "取消", tint: .secondary) {
                    withAnimation(.snappy(duration: 0.2)) { editingServer = false }
                }
                AdminMiniButton(title: "自动选", tint: .secondary) {
                    Task {
                        let picked = await AdminAPI.autoPickLine()
                        await MainActor.run {
                            store.updateBase(AdminAPI.base)
                            serverDraft = store.base
                            lineNote = picked == nil ? "两条线路都连不上。" : "已切到\(picked!)。"
                        }
                    }
                }
                AdminMiniButton(title: "用它", tint: AdminSkin.brand, filled: true) {
                    store.updateBase(serverDraft)
                    serverDraft = store.base
                    withAnimation(.snappy(duration: 0.2)) { editingServer = false }
                }
            }
            if let lineNote {
                Text(lineNote)
                    .font(.system(size: 11))
                    .foregroundStyle(AdminSkin.brand)
            } else {
                Text("换了服务器要重新登录（旧的令牌在另一台上不认）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await store.signIn(username: name, password: password) }
    }
}
