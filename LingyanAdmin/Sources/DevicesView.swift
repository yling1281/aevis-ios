import SwiftUI

/// 设备授权：一机一码。待授权排最前，方便一眼看到要发码的。
struct DevicesView: View {
    @State private var state: LoadState = .idle
    @State private var stats: [String: Any] = [:]
    @State private var rows: [DeviceItem] = []
    @State private var filter = ""
    @State private var picked: DeviceItem?
    @State private var showQuick = false

    private let filters: [(String, String)] = [
        ("", "全部"), ("pending", "待授权"), ("active", "已授权"), ("blocked", "已停用"),
    ]

    var body: some View {
        NavigationStack {
            List {
                if case .fail = state {
                    StateBanner(state: state) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }

                Section {
                    HStack(spacing: 8) {
                        mini("待授权", "\(stats.i("pending"))", .orange)
                        mini("已授权", "\(stats.i("active"))", .green)
                        mini("已停用", "\(stats.i("blocked"))", .red)
                        mini("在线", "\(stats.i("online"))", .teal)
                    }
                }

                Section {
                    Picker("筛选", selection: $filter) {
                        ForEach(filters, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                if rows.isEmpty && state == .done {
                    Text("这个筛选下没有设备").font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(rows) { d in
                    Button { picked = d } label: { rowView(d) }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("设备授权")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showQuick = true } label: { Image(systemName: "plus.circle") }
                }
            }
            .refreshable { await load() }
            .task(id: filter) { await load() }
            .sheet(item: $picked) { d in
                DeviceDetailView(device: d) { Task { await load() } }
            }
            .sheet(isPresented: $showQuick) {
                QuickUnlockView { Task { await load() } }
            }
        }
    }

    private func mini(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.callout.weight(.bold).monospacedDigit()).foregroundStyle(c)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func rowView(_ d: DeviceItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.display).font(.callout.weight(.semibold)).lineLimit(1)
                    Chip(text: d.statusLabel, tint: Tone.color(Tone.forDevice(d.status)))
                }
                Text(d.deviceCode).font(.caption2.monospaced()).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if !d.verifyCode.isEmpty {
                        Text("码 \(d.verifyCode)").font(.caption2.monospaced())
                            .foregroundStyle(.orange)
                    }
                    if !d.expiresAt.isEmpty {
                        Text("到期 \(Fmt.day(d.expiresAt))").font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.time(d.lastSeen)).font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            stats = DemoData.deviceStats
            rows = DemoData.devices.filter { filter.isEmpty || $0.status == filter }
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/device/list")
            stats = r.dict("stats")
            var all = r.list("rows").map { DeviceItem(raw: $0) }
            if !filter.isEmpty { all = all.filter { $0.status == filter } }
            rows = all
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}

/// 设备详情 + 全部操作。
struct DeviceDetailView: View {
    let device: DeviceItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var issued = ""
    @State private var askCode = false
    @State private var minutes = ""
    @State private var askMeta = false
    @State private var newName = ""
    @State private var newNote = ""
    @State private var newDays = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("设备") {
                    KVRow(k: "名称", v: device.name)
                    KVRow(k: "设备码", v: device.deviceCode, mono: true)
                    KVRow(k: "状态", v: device.statusLabel)
                    KVRow(k: "平台", v: device.platform)
                    KVRow(k: "版本", v: device.appVersion)
                }
                Section("授权") {
                    KVRow(k: "解锁码", v: device.verifyCode, mono: true)
                    KVRow(k: "码到期", v: Fmt.time(device.codeExpires))
                    KVRow(k: "用过次数", v: "\(device.codeUses)")
                    KVRow(k: "授权到期", v: Fmt.day(device.expiresAt))
                    KVRow(k: "激活于", v: Fmt.time(device.activatedAt))
                    KVRow(k: "最后在线", v: Fmt.time(device.lastSeen))
                    if device.attempts > 0 {
                        KVRow(k: "错误次数", v: "\(device.attempts)")
                    }
                }
                Section("来源") {
                    KVRow(k: "备注", v: device.note)
                    KVRow(k: "IP", v: device.ip, mono: true)
                    KVRow(k: "UA", v: device.ua)
                    KVRow(k: "创建", v: Fmt.time(device.createdAt))
                }

                if !issued.isEmpty {
                    Section("刚生成的解锁码") {
                        Text(issued).font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Button("复制") { copyToPasteboard(issued, what: "解锁码已复制") }
                            .font(.footnote)
                    }
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
                        minutes = ""
                        askCode = true
                    } label: {
                        Label("生成 / 重发解锁码", systemImage: "key.fill")
                    }
                    .disabled(busy)

                    Button {
                        newName = device.name
                        newNote = device.note
                        newDays = ""
                        askMeta = true
                    } label: {
                        Label("改名称 / 备注 / 授权天数", systemImage: "square.and.pencil")
                    }
                    .disabled(busy)

                    if device.status == "blocked" {
                        Button {
                            Task { await setStatus("active", "已恢复授权") }
                        } label: {
                            Label("恢复授权", systemImage: "play.circle")
                        }
                        .disabled(busy)
                    } else {
                        Button(role: .destructive) {
                            Task { await setStatus("blocked", "已停用") }
                        } label: {
                            Label("停用这台设备", systemImage: "hand.raised.fill")
                        }
                        .disabled(busy)
                    }

                    Button {
                        Task { await revoke() }
                    } label: {
                        Label("吊销登录状态（需重新解锁）", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(busy)

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除设备记录", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("设备详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("解锁码有效时长（分钟）", isPresented: $askCode) {
                TextField("留空 = 默认 1 年", text: $minutes).keyboardType(.numberPad)
                Button("取消", role: .cancel) {}
                Button("生成") { Task { await issue() } }
            } message: {
                Text("这个码是长期码、可重复用：客户换机器/重装后用同一串还能恢复。")
            }
            .alert("修改设备", isPresented: $askMeta) {
                TextField("名称", text: $newName)
                TextField("备注", text: $newNote)
                TextField("授权天数（留空不动）", text: $newDays)
                    .keyboardType(.numbersAndPunctuation)
                Button("取消", role: .cancel) {}
                Button("保存") { Task { await saveMeta() } }
            }
            .confirmationDialog("确定删除这条设备记录？", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await del() } }
                Button("取消", role: .cancel) {}
            }
            .overlay {
                if busy {
                    ProgressView().padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func issue() async {
        var body: [String: Any] = [:]
        if let n = Int(minutes.trimmingCharacters(in: .whitespaces)), n > 0 { body["minutes"] = n }
        await act { try await API.shared.post("/api/device/\(device.id)/code", body: body) }
    }

    private func setStatus(_ st: String, _ word: String) async {
        await act(okWord: word) {
            try await API.shared.post("/api/device/\(device.id)/status", body: ["status": st])
        }
    }

    private func revoke() async {
        await act(okWord: "已吊销") {
            try await API.shared.post("/api/device/\(device.id)/revoke")
        }
    }

    private func saveMeta() async {
        var body: [String: Any] = [:]
        if !newName.trimmingCharacters(in: .whitespaces).isEmpty { body["name"] = newName }
        if !newNote.isEmpty || !device.note.isEmpty { body["note"] = newNote }
        if let n = Int(newDays.trimmingCharacters(in: .whitespaces)) { body["days"] = n }
        await act(okWord: "已保存") {
            try await API.shared.post("/api/device/\(device.id)/meta", body: body)
        }
    }

    private func del() async {
        await act(okWord: "已删除") {
            try await API.shared.delete("/api/device/\(device.id)")
        }
    }

    private func act(okWord: String = "已处理",
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
            let v = r.s("verify_code")
            if !v.isEmpty { issued = v }
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}

/// 后台「直接解锁」：粘一个设备码进来，当场出解锁码。
struct QuickUnlockView: View {
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var issued = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("设备码（形如 A9B5-E862-5B9C）", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                    TextField("给个名字（可空）", text: $name).font(.callout)
                } footer: {
                    Text("客户把设备码发过来就能直接开，不用他先上报、也不用生成卡密。")
                        .font(.caption2)
                }

                if !issued.isEmpty {
                    Section("解锁码（长期、可重复用）") {
                        Text(issued).font(.title3.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Button("复制解锁码") { copyToPasteboard(issued, what: "解锁码已复制") }
                            .font(.footnote)
                    }
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
                            Text(busy ? "正在生成…" : "生成解锁码").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("直接解锁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        if AppConfig.isDemo {
            msgOK = true; issued = "DEMO-9999-DEMO-9999"
            msg = "演示模式：生成了一串假解锁码"
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await API.shared.post("/api/device/quick-unlock", body: [
                "device_code": code.trimmingCharacters(in: .whitespaces),
                "name": name.trimmingCharacters(in: .whitespaces),
            ])
            msgOK = true
            msg = r.s("msg")
            let v = r.s("verify_code")
            if !v.isEmpty { issued = v }
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
