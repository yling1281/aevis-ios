import SwiftUI

/// 账号管理：建号 / 改密 / 设撤管理员 / 删号 + 开放注册开关。
/// 撤销管理员、删除管理员、改管理员密码都只有**站长**能做（服务器会拦）。
struct UsersView: View {
    @ObservedObject private var cfg = AppConfig.shared

    @State private var state: LoadState = .idle
    @State private var rows: [UserItem] = []
    @State private var allowRegister = false
    @State private var picked: UserItem?
    @State private var showNew = false
    @State private var search = ""

    private var shown: [UserItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return rows }
        return rows.filter { $0.username.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if case .fail = state {
                    StateBanner(state: state) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }

                Section {
                    Toggle("开放自助注册", isOn: Binding(
                        get: { allowRegister },
                        set: { v in
                            allowRegister = v
                            Task { await setPolicy(v) }
                        }
                    ))
                } footer: {
                    Text("打开后，任何人可以在官网/客户端自己注册账号；关着就只能由你在这里建号。")
                        .font(.caption2)
                }

                Section {
                    HStack(spacing: 8) {
                        Text("共 \(rows.count) 个账号").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        if !cfg.isOwner {
                            Text("（只有站长能设/撤管理员）")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if shown.isEmpty && state == .done {
                    Text("没有匹配的账号").font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(shown) { u in
                    Button { picked = u } label: { rowView(u) }
                        .buttonStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "搜账号名")
            .navigationTitle("账号管理")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $picked) { u in
                UserDetailView(user: u, isOwner: cfg.isOwner) {
                    Task { await load() }
                }
            }
            .sheet(isPresented: $showNew) {
                NewUserView(canCreateAdmin: cfg.isOwner) { Task { await load() } }
            }
        }
    }

    private func rowView(_ u: UserItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(u.username).font(.callout.weight(.semibold))
                    Chip(text: u.roleLabel,
                         tint: u.isOwner ? .red : (u.isAdmin ? .orange : .blue))
                }
                HStack(spacing: 10) {
                    Text("创建 \(Fmt.day(u.createdAt))").font(.caption2)
                        .foregroundStyle(.secondary)
                    if !u.lastLogin.isEmpty {
                        Text("最近登录 \(Fmt.time(u.lastLogin))").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            rows = DemoData.users
            allowRegister = false
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/auth/users")
            allowRegister = r.b("allow_register")
            rows = r.list("users").map { UserItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }

    private func setPolicy(_ v: Bool) async {
        if AppConfig.isDemo { return }
        do {
            _ = try await API.shared.put("/api/auth/policy", body: ["allow_register": v])
            Toast.shared.show(v ? "已开放自助注册" : "已关闭自助注册")
        } catch {
            allowRegister = !v      // 失败就拨回去，别让界面跟服务器不一致
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
    }
}

// MARK: - 账号详情

struct UserDetailView: View {
    let user: UserItem
    let isOwner: Bool
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var askPw = false
    @State private var pw = ""
    @State private var confirmDel = false
    @State private var confirmRole = false

    var body: some View {
        NavigationStack {
            Form {
                Section("账号") {
                    KVRow(k: "账号名", v: user.username)
                    KVRow(k: "身份", v: user.roleLabel)
                    KVRow(k: "创建", v: Fmt.time(user.createdAt))
                    KVRow(k: "最近登录", v: Fmt.time(user.lastLogin))
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
                        pw = ""
                        askPw = true
                    } label: {
                        Label("重置密码", systemImage: "key")
                    }
                    .disabled(busy || (user.isAdmin && !isOwner))

                    if isOwner && !user.isOwner {
                        Button {
                            confirmRole = true
                        } label: {
                            Label(user.isAdmin ? "撤销管理员" : "设为管理员",
                                  systemImage: user.isAdmin ? "person.badge.minus" : "checkmark.shield")
                        }
                        .disabled(busy)
                    }

                    Button(role: .destructive) {
                        confirmDel = true
                    } label: {
                        Label("删除账号", systemImage: "trash")
                    }
                    .disabled(busy || user.isOwner || (user.isAdmin && !isOwner))
                } footer: {
                    if user.isAdmin && !isOwner {
                        Text("这是管理员账号：只有站长能改它的密码或删除它。")
                    } else if user.isOwner {
                        Text("站长账号不能删除、也不能改角色。")
                    }
                }
            }
            .navigationTitle("账号详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("重置密码", isPresented: $askPw) {
                TextField("新密码（至少 6 位）", text: $pw)
                Button("取消", role: .cancel) {}
                Button("重置") { Task { await resetPw() } }
            } message: {
                Text("改完把这个新密码发给「\(user.username)」，让他自己登进去再改。")
            }
            .confirmationDialog(user.isAdmin ? "撤销「\(user.username)」的管理员身份？" : "把「\(user.username)」设为管理员？",
                                isPresented: $confirmRole, titleVisibility: .visible) {
                Button(user.isAdmin ? "撤销" : "设为管理员",
                       role: user.isAdmin ? .destructive : .none) {
                    Task { await setRole(!user.isAdmin) }
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("确定删除账号「\(user.username)」？",
                                isPresented: $confirmDel, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await del() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个账号自己的对外 API Key 也会一起失效。")
            }
            .overlay {
                if busy {
                    ProgressView().padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func resetPw() async {
        let p = pw.trimmingCharacters(in: .whitespaces)
        guard p.count >= 6 else {
            msgOK = false; msg = "密码至少 6 位"
            return
        }
        await act(okWord: "密码已重置") {
            try await API.shared.post("/api/auth/users/\(user.id)/password", body: ["password": p])
        }
        pw = ""
    }

    private func setRole(_ admin: Bool) async {
        await act(okWord: admin ? "已设为管理员" : "已撤销管理员") {
            try await API.shared.post("/api/auth/users/\(user.id)/role", body: ["is_admin": admin])
        }
    }

    private func del() async {
        await act(okWord: "已删除") {
            try await API.shared.delete("/api/auth/users/\(user.id)")
        }
    }

    private func act(okWord: String,
                     _ run: () async throws -> [String: Any]) async {
        if AppConfig.isDemo {
            msgOK = true; msg = "演示模式：\(okWord)（没有真的改数据）"
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await run()
            msgOK = true
            msg = r.s("msg").isEmpty ? okWord : r.s("msg")
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}

// MARK: - 新建账号

struct NewUserView: View {
    let canCreateAdmin: Bool
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pw = ""
    @State private var isAdmin = false
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("账号名（2–32 字）", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("密码（至少 6 位）", text: $pw)
                    if canCreateAdmin {
                        Toggle("设为管理员", isOn: $isAdmin)
                    }
                } footer: {
                    Text(canCreateAdmin
                         ? "管理员能进这个后台、管设备/卡密/订单；普通账号是给客户的。"
                         : "只有站长能创建管理员账号。")
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
                        Task { await go() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "正在创建…" : "创建").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).count < 2 || pw.count < 6)
                }
            }
            .navigationTitle("新建账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        if AppConfig.isDemo {
            msgOK = true; msg = "演示模式：账号「\(name)」创建成功（没有真的建）"
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await API.shared.post("/api/auth/users", body: [
                "username": name.trimmingCharacters(in: .whitespaces),
                "password": pw,
                "is_admin": isAdmin,
            ])
            msgOK = true
            msg = r.s("msg")
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
