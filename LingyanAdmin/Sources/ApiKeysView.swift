import SwiftUI

/// 对外 API Key：给**第三方**用的钥匙（拿码 / 验证 / 上传）。
///
/// 规则（跟电脑后台一致）：
///   · 每个管理员有自己的「我的 Key」，**只有本人**能看到/重新生成（站长也看不到你的明文）；
///   · 不绑账号的「外部合作方 Key」只有**站长**能发、能管；
///   · 明文只在生成的那一刻返回一次，服务器只存 sha256。
struct ApiKeysView: View {
    @State private var state: LoadState = .idle
    @State private var mine: KeyItem?
    @State private var keys: [KeyItem] = []
    @State private var isOwner = false
    @State private var showNew = false
    @State private var showRegen = false
    @State private var freshKey = ""       // 刚生成出来的明文，只显示这一次
    @State private var picked: KeyItem?

    private var external: [KeyItem] { keys.filter { $0.isExternal } }
    private var others: [KeyItem] {
        guard let m = mine else { return [] }
        return keys.filter { !$0.isExternal && $0.id != m.id }
    }

    var body: some View {
        List {
            if case .fail = state {
                StateBanner(state: state) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if !freshKey.isEmpty {
                Section("刚生成的 Key（只显示这一次）") {
                    Text(freshKey).font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button("复制 Key") { copyToPasteboard(freshKey, what: "Key 已复制") }
                        .font(.footnote)
                    Button("我知道了，收起") { freshKey = "" }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let m = mine {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(m.name).font(.callout.weight(.semibold))
                            Chip(text: m.enabled ? "启用中" : "已停用",
                                 tint: m.enabled ? .green : .red)
                        }
                        KVRow(k: "提示", v: m.hint, mono: true)
                        KVRow(k: "权限", v: m.scopesLabel)
                        KVRow(k: "备注", v: m.note)
                        KVRow(k: "创建", v: Fmt.time(m.createdAt))
                        KVRow(k: "最近使用", v: Fmt.time(m.lastUsedAt))
                        KVRow(k: "来源 IP", v: m.lastUsedIP, mono: true)
                    }
                    Button {
                        showRegen = true
                    } label: {
                        Label("重新生成（旧的立刻作废）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .font(.footnote)

                    Button {
                        Task { await enable(m.id, !m.enabled) }
                    } label: {
                        Label(m.enabled ? "停用这把 Key" : "重新启用",
                              systemImage: m.enabled ? "pause.circle" : "play.circle")
                    }
                    .font(.footnote)
                } else {
                    Text("你还没有自己的 Key。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        showNew = true
                    } label: {
                        Label("生成我的 Key", systemImage: "key.fill")
                    }
                    .font(.footnote)
                }
            } header: {
                Text("我的 Key")
            } footer: {
                Text("这是**你本人**的钥匙，别人（包括站长）都看不到它的明文。"
                     + "给第三方用时，把生成时显示的整串复制给他。")
                    .font(.caption2)
            }

            if isOwner {
                Section {
                    if external.isEmpty {
                        Text("还没有发给外部合作方的 Key")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(external) { k in
                        Button { picked = k } label: { keyRow(k) }
                            .buttonStyle(.plain)
                    }
                    Button {
                        showNew = true
                    } label: {
                        Label("发一把给外部合作方", systemImage: "paperplane")
                    }
                    .font(.footnote)
                } header: {
                    Text("外部合作方 Key（站长专属）")
                } footer: {
                    Text("不绑任何管理员账号的钥匙：发出去之后不会因为某个管理员被删而失效。")
                        .font(.caption2)
                }
            }

            if isOwner && !others.isEmpty {
                Section {
                    ForEach(others) { k in
                        keyRow(k)
                    }
                } header: {
                    Text("其他管理员的 Key")
                } footer: {
                    Text("只能看，不能管 —— 明文只在本人手里，要换得他本人在自己手机上重新生成。")
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("对外 API")
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showNew) {
            NewKeyView(isOwner: isOwner, hasMine: mine != nil) { plain in
                freshKey = plain
                Task { await load() }
            }
        }
        .sheet(isPresented: $showRegen) {
            RegenKeyView(current: mine) { plain in
                freshKey = plain
                Task { await load() }
            }
        }
        .sheet(item: $picked) { k in
            ExternalKeyView(key: k) { Task { await load() } }
        }
    }

    private func keyRow(_ k: KeyItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(k.name).font(.callout.weight(.semibold))
                Chip(text: k.enabled ? "启用中" : "已停用", tint: k.enabled ? .green : .red)
                if k.isExternal { Chip(text: "外部", tint: .orange) }
            }
            Text(k.hint).font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(k.scopesLabel).font(.caption2).foregroundStyle(.secondary)
                if !k.ownerName.isEmpty {
                    Text("归属 \(k.ownerName)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.time(k.lastUsedAt)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            mine = KeyItem(raw: DemoData.mineKey)
            keys = DemoData.keys.map { KeyItem(raw: $0) }
            isOwner = true
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/oa/keys")
            isOwner = r.dict("me").b("is_owner")
            let m = r.dict("mine")
            mine = m.isEmpty ? nil : KeyItem(raw: m)
            keys = r.list("keys").map { KeyItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }

    private func enable(_ kid: Int, _ on: Bool) async {
        if AppConfig.isDemo {
            Toast.shared.show("演示模式：\(on ? "已启用" : "已停用")")
            return
        }
        do {
            _ = try await API.shared.post("/api/oa/keys/\(kid)/enabled", body: ["enabled": on])
            Toast.shared.show(on ? "已启用" : "已停用")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
    }
}

// MARK: - 新建 Key

struct NewKeyView: View {
    let isOwner: Bool
    let hasMine: Bool
    var onMade: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""
    @State private var forExternal = false
    @State private var useRead = false
    @State private var useCard = true
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false

    var body: some View {
        NavigationStack {
            Form {
                if isOwner {
                    Section {
                        Toggle("发给外部合作方（不绑账号）", isOn: $forExternal)
                    } footer: {
                        Text(forExternal
                             ? "这把 Key 不属于任何管理员账号，发出去后不会因为某个管理员被删而失效。站长专属。"
                             : "不勾就是生成你自己的「我的 Key」（一人一把）。")
                            .font(.caption2)
                    }
                }

                if !forExternal && hasMine {
                    Section {
                        Text("你已经有自己的 Key 了。要换就用列表里的「重新生成」。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section {
                    TextField("名字（如：XX 素材网）", text: $name)
                    TextField("备注（可空）", text: $note)
                }

                Section {
                    Toggle("拿码 / 验证（card）", isOn: $useCard)
                    Toggle("查素材 / 统计 / 下载（read）", isOn: $useRead)
                } header: {
                    Text("能做什么")
                } footer: {
                    Text("第三方一般只给「拿码 / 验证」。查素材 / 统计这些涉及你自己的数据，按需再给。")
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
                            Text(busy ? "正在生成…" : "生成").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle(forExternal ? "发外部 Key" : "生成我的 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        var scopes: [String] = []
        if useCard { scopes.append("card") }
        if useRead { scopes.append("read") }
        if scopes.isEmpty { scopes = ["card"] }
        if AppConfig.isDemo {
            let demo = "LYAPI-DEMO0000DEMO0000DEMO0000"
            msgOK = true
            msg = "演示模式"
            onMade(demo)
            dismiss()
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await API.shared.post("/api/oa/keys", body: [
                "name": name.trimmingCharacters(in: .whitespaces),
                "note": note,
                "scopes": scopes,
                "unbound": forExternal,
            ])
            let plain = r.dict("item").s("key")
            busy = false
            onMade(plain)
            dismiss()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
            busy = false
        }
    }
}

// MARK: - 重新生成（换权限）

struct RegenKeyView: View {
    let current: KeyItem?
    var onMade: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var useRead = false
    @State private var useCard = true
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("旧的 Key 会**立刻作废**，已经把它填进第三方的软件里要一起换掉。")
                        .font(.footnote).foregroundStyle(.orange)
                }

                Section("名字") {
                    TextField("Key 名字", text: $name)
                }

                Section {
                    Toggle("拿码 / 验证（card）", isOn: $useCard)
                    Toggle("查素材 / 统计 / 下载（read）", isOn: $useRead)
                } header: {
                    Text("权限")
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
                            Text(busy ? "正在重新生成…" : "重新生成").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("重新生成我的 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = current?.name ?? ""
                useRead = current?.scopes.contains("read") ?? false
                useCard = current?.scopes.contains("card") ?? true
            }
        }
    }

    private func go() async {
        var scopes: [String] = []
        if useCard { scopes.append("card") }
        if useRead { scopes.append("read") }
        if scopes.isEmpty { scopes = ["card"] }
        if AppConfig.isDemo {
            onMade("LYAPI-DEMO0000DEMO0000DEMO0000")
            dismiss()
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await API.shared.post("/api/oa/keys/regenerate", body: [
                "name": name.trimmingCharacters(in: .whitespaces),
                "scopes": scopes,
            ])
            let plain = r.dict("item").s("key")
            busy = false
            onMade(plain)
            dismiss()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
            busy = false
        }
    }
}

// MARK: - 外部 Key 管理（站长）

struct ExternalKeyView: View {
    let key: KeyItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var confirmDel = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    KVRow(k: "名字", v: key.name)
                    KVRow(k: "提示", v: key.hint, mono: true)
                    KVRow(k: "权限", v: key.scopesLabel)
                    KVRow(k: "备注", v: key.note)
                    KVRow(k: "状态", v: key.enabled ? "启用中" : "已停用")
                }
                Section("使用情况") {
                    KVRow(k: "创建", v: Fmt.time(key.createdAt))
                    KVRow(k: "最近使用", v: Fmt.time(key.lastUsedAt))
                    KVRow(k: "来源 IP", v: key.lastUsedIP, mono: true)
                }
                Section {
                    Button {
                        Task { await enable(!key.enabled) }
                    } label: {
                        Label(key.enabled ? "停用" : "重新启用",
                              systemImage: key.enabled ? "pause.circle" : "play.circle")
                    }
                    .disabled(busy)

                    Button(role: .destructive) {
                        confirmDel = true
                    } label: {
                        Label("删除这把 Key", systemImage: "trash")
                    }
                    .disabled(busy)
                } footer: {
                    Text("明文只在生成时显示过一次，服务器上只有摘要 —— 找不回，要换只能删掉重建。")
                        .font(.caption2)
                }
            }
            .navigationTitle("外部 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("确定删除「\(key.name)」？", isPresented: $confirmDel,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await del() } }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func enable(_ on: Bool) async {
        if AppConfig.isDemo { Toast.shared.show("演示模式"); return }
        busy = true
        do {
            _ = try await API.shared.post("/api/oa/keys/\(key.id)/enabled", body: ["enabled": on])
            Toast.shared.show(on ? "已启用" : "已停用")
            onChanged()
            dismiss()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
        busy = false
    }

    private func del() async {
        if AppConfig.isDemo { Toast.shared.show("演示模式"); return }
        busy = true
        do {
            _ = try await API.shared.delete("/api/oa/keys/\(key.id)")
            Toast.shared.show("已删除")
            onChanged()
            dismiss()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
        busy = false
    }
}
