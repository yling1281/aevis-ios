import SwiftUI

/// 卡密：批量生成、停用、换绑、删，外加按串查询。
struct CardsView: View {
    @State private var state: LoadState = .idle
    @State private var stats: [String: Any] = [:]
    @State private var rows: [CardItem] = []
    @State private var filter = ""
    @State private var picked: CardItem?
    @State private var showBatch = false
    @State private var showQuery = false

    private let filters: [(String, String)] = [
        ("", "全部"), ("unused", "未使用"), ("bound", "已绑定"), ("disabled", "已停用"),
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
                        mini("未使用", "\(stats.i("unused"))", .green)
                        mini("已绑定", "\(stats.i("bound"))", .orange)
                        mini("已停用", "\(stats.i("disabled"))", .red)
                        mini("今日新卡", "\(stats.i("today"))", .purple)
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
                    Text("这个筛选下没有卡密").font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(rows) { c in
                    Button { picked = c } label: { rowView(c) }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("卡密")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showQuery = true } label: { Image(systemName: "magnifyingglass") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showBatch = true } label: { Image(systemName: "plus.circle") }
                }
            }
            .refreshable { await load() }
            .task(id: filter) { await load() }
            .sheet(item: $picked) { c in
                CardDetailView(card: c) { Task { await load() } }
            }
            .sheet(isPresented: $showBatch) {
                CardBatchView { Task { await load() } }
            }
            .sheet(isPresented: $showQuery) { CardQueryView() }
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

    private func rowView(_ c: CardItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.code).font(.callout.monospaced().weight(.semibold))
                    Chip(text: c.statusLabel, tint: Tone.color(Tone.forCard(c.status)))
                }
                HStack(spacing: 10) {
                    Text(c.planName.isEmpty ? "—" : c.planName).font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(c.days)天").font(.caption2).foregroundStyle(.secondary)
                    if !c.username.isEmpty {
                        Text(c.username).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !c.deviceCode.isEmpty {
                    Text(c.deviceCode).font(.caption2.monospaced())
                        .foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.time(c.createdAt)).font(.caption2.monospacedDigit())
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
            stats = DemoData.cardStats
            rows = DemoData.cards.filter { filter.isEmpty || $0.status == filter }
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/card/list", query: ["status": filter])
            stats = r.dict("stats")
            rows = r.list("rows").map { CardItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}

// MARK: - 卡密详情

struct CardDetailView: View {
    let card: CardItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var askRebind = false
    @State private var newCode = ""
    @State private var askNote = false
    @State private var note = ""
    @State private var confirmDelete = false
    @State private var keyOut = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("卡密") {
                    KVRow(k: "卡号", v: card.code, mono: true)
                    KVRow(k: "套餐", v: card.planName)
                    KVRow(k: "天数", v: "\(card.days)")
                    KVRow(k: "金额", v: Fmt.money(card.amount))
                    KVRow(k: "状态", v: card.statusLabel)
                }
                Section("绑定") {
                    KVRow(k: "账号", v: card.username)
                    KVRow(k: "设备码", v: card.deviceCode, mono: true)
                    KVRow(k: "设备密钥", v: card.deviceKey, mono: true)
                    KVRow(k: "订单号", v: card.orderNo, mono: true)
                }
                Section("其他") {
                    KVRow(k: "批次", v: card.batch, mono: true)
                    KVRow(k: "备注", v: card.note)
                    KVRow(k: "创建", v: Fmt.time(card.createdAt))
                    KVRow(k: "绑定于", v: Fmt.time(card.boundAt))
                    KVRow(k: "到期", v: Fmt.day(card.expiresAt))
                }

                if !keyOut.isEmpty {
                    Section("新的设备密钥") {
                        Text(keyOut).font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Button("复制") { copyToPasteboard(keyOut, what: "设备密钥已复制") }
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
                    Button { copyToPasteboard(card.code, what: "卡密已复制") } label: {
                        Label("复制卡密", systemImage: "doc.on.doc")
                    }

                    Button {
                        newCode = card.deviceCode
                        askRebind = true
                    } label: {
                        Label("换绑设备（换机器）", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(busy)

                    Button {
                        note = card.note
                        askNote = true
                    } label: {
                        Label("改备注", systemImage: "square.and.pencil")
                    }
                    .disabled(busy)

                    if card.status == "disabled" {
                        Button {
                            Task { await setStatus("unused", "已恢复") }
                        } label: {
                            Label("恢复成「未使用」", systemImage: "play.circle")
                        }
                        .disabled(busy)
                    } else {
                        Button(role: .destructive) {
                            Task { await setStatus("disabled", "已停用") }
                        } label: {
                            Label("停用（对应设备一起停）", systemImage: "hand.raised.fill")
                        }
                        .disabled(busy)
                    }

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除卡密", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("卡密详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
            .alert("换绑到新的设备码", isPresented: $askRebind) {
                TextField("设备码（形如 A9B5-E862-5B9C）", text: $newCode)
                    .textInputAutocapitalization(.characters)
                Button("取消", role: .cancel) {}
                Button("换绑") { Task { await rebind() } }
            } message: {
                Text("会同时生成新的设备密钥，旧机器的密钥立刻失效。")
            }
            .alert("备注", isPresented: $askNote) {
                TextField("给这张卡写点备注", text: $note)
                Button("取消", role: .cancel) {}
                Button("保存") { Task { await saveNote() } }
            }
            .confirmationDialog("确定删除这张卡密？", isPresented: $confirmDelete,
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

    private func setStatus(_ st: String, _ word: String) async {
        await act(okWord: word) {
            try await API.shared.post("/api/card/\(card.id)/status", body: ["status": st])
        }
    }

    private func rebind() async {
        await act(okWord: "已换绑") {
            try await API.shared.post("/api/card/\(card.id)/rebind",
                                      body: ["device_code": newCode.trimmingCharacters(in: .whitespaces)])
        }
    }

    private func saveNote() async {
        await act(okWord: "备注已保存") {
            try await API.shared.post("/api/card/\(card.id)/note", body: ["note": note])
        }
    }

    private func del() async {
        await act(okWord: "已删除") {
            try await API.shared.delete("/api/card/\(card.id)")
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
            let k = r.s("device_key")
            if !k.isEmpty { keyOut = k }
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}

// MARK: - 批量生成

struct CardBatchView: View {
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var count = "10"
    @State private var planName = ""
    @State private var days = "365"
    @State private var amount = ""
    @State private var note = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var made: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("数量（1–500）", text: $count).keyboardType(.numberPad)
                    TextField("套餐名（如：年费会员）", text: $planName)
                    TextField("天数", text: $days).keyboardType(.numberPad)
                    TextField("金额（可空）", text: $amount).keyboardType(.decimalPad)
                    TextField("备注（可空）", text: $note)
                } footer: {
                    Text("一次生成一批（同一个批次号，方便对账）。生成的卡密在下面，可以一次全部复制。")
                        .font(.caption2)
                }

                if !made.isEmpty {
                    Section("刚生成 \(made.count) 张") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(made, id: \.self) { c in
                                    Text(c).font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)
                        Button("复制全部") {
                            copyToPasteboard(made.joined(separator: "\n"), what: "已复制")
                        }
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
                            Text(busy ? "正在生成…" : "生成").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("批量生成卡密")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        let n = max(1, min(500, Int(count.trimmingCharacters(in: .whitespaces)) ?? 1))
        let d = max(1, Int(days.trimmingCharacters(in: .whitespaces)) ?? 365)
        let amt = Double(amount.trimmingCharacters(in: .whitespaces)) ?? 0
        if AppConfig.isDemo {
            msgOK = true
            made = (1...min(n, 5)).map { String(format: "LY-DEMO-%04d-0000", $0) }
            msg = "演示模式：生成了 \(made.count) 张假卡密"
            return
        }
        busy = true
        msg = ""
        do {
            let r = try await API.shared.post("/api/card/batch", body: [
                "count": n, "plan_name": planName, "days": d, "amount": amt, "note": note,
            ])
            msgOK = true
            msg = r.s("msg")
            made = r.strings("codes")
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}

// MARK: - 按串查询（只读，不消费）

struct CardQueryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var state: LoadState = .idle
    @State private var check: [String: Any] = [:]
    @State private var verify: [String: Any] = [:]
    @State private var hasResult = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("粘一串卡密", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                } footer: {
                    Text("只查不改：不会消费卡密，也不会触发绑定。")
                        .font(.caption2)
                }

                if state == .done && hasResult && check.isEmpty {
                    Section { Text("查不到这张卡密").font(.footnote).foregroundStyle(.secondary) }
                }

                if !check.isEmpty {
                    Section("卡密") {
                        KVRow(k: "卡号", v: check.s("code"), mono: true)
                        KVRow(k: "状态", v: check.s("status"))
                        KVRow(k: "套餐", v: check.s("plan_name"))
                        KVRow(k: "天数", v: "\(check.i("days"))")
                        KVRow(k: "金额", v: Fmt.money(check.d("amount")))
                        KVRow(k: "账号", v: check.s("username"))
                        KVRow(k: "设备码", v: check.s("device_code"), mono: true)
                        KVRow(k: "批次", v: check.s("batch"), mono: true)
                        KVRow(k: "备注", v: check.s("note"))
                        KVRow(k: "绑定于", v: Fmt.time(check.s("bound_at")))
                        KVRow(k: "到期", v: Fmt.day(check.s("expires_at")))
                    }
                }

                if !verify.isEmpty {
                    Section("能不能用") {
                        KVRow(k: "结论", v: verify.b("valid") ? "可以（还没被用过）" : "不行")
                        KVRow(k: "说明", v: verify.s("reason"))
                    }
                }

                Section {
                    Button {
                        Task { await go() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "查询中…" : "查询").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4)
                }
            }
            .navigationTitle("查卡密")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        let c = code.trimmingCharacters(in: .whitespaces)
        if AppConfig.isDemo {
            check = ["code": c, "status": "bound", "plan_name": "年费会员", "days": 365,
                     "amount": 128.0, "username": "客户甲", "device_code": "A9B5-E862-5B9C",
                     "batch": "B2610081200-3KD", "note": "",
                     "bound_at": "2026-10-01T09:20:00", "expires_at": "2027-10-01"]
            verify = ["valid": false, "reason": "这张卡密已经用过了（一个卡密只能绑一个账号）"]
            hasResult = true
            state = .done
            return
        }
        busy = true
        do {
            // 「能不能用」走公开的验卡接口；明细在列表里按卡号找（跟电脑后台一个做法）
            verify = try await API.shared.post("/api/card/verify", body: ["code": c])
            let all = try await API.shared.get("/api/card/list")
            let key = c.uppercased()
            check = all.list("rows").first {
                ($0["code"] as? String ?? "").uppercased() == key
            } ?? [:]
            hasResult = true
            state = .done
        } catch {
            hasResult = false
            check = [:]
            state = .fail((error as? APIError)?.message ?? error.localizedDescription,
                          (error as? APIError)?.status ?? 0)
        }
        busy = false
    }
}
