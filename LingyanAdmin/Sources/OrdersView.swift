import SwiftUI

/// 订单：自助购买的下单记录，确认到账 → 自动给设备发解锁码。
struct OrdersView: View {
    @State private var state: LoadState = .idle
    @State private var stats: [String: Any] = [:]
    @State private var rows: [OrderItem] = []
    @State private var filter = ""
    @State private var picked: OrderItem?

    private let filters: [(String, String)] = [
        ("", "全部"), ("pending", "待处理"), ("paid", "已付款"),
        ("done", "已发码"), ("canceled", "已取消"),
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
                        mini("待处理", "\(stats.i("pending"))", .orange)
                        mini("已付款", "\(stats.i("paid"))", .blue)
                        mini("已发码", "\(stats.i("done"))", .green)
                    }
                    HStack(spacing: 8) {
                        mini("今日", "\(stats.i("today"))", .purple)
                        mini("今日收入", Fmt.moneyGrouped(stats.d("income_today")), .red)
                        mini("累计收入", Fmt.moneyGrouped(stats.d("income")), .teal)
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
                    Text("这个筛选下没有订单").font(.footnote).foregroundStyle(.secondary)
                }

                ForEach(rows) { o in
                    Button { picked = o } label: { rowView(o) }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("订单")
            .refreshable { await load() }
            // 筛选一变就重拉（`.task(id:)` 首次出现时也会跑一次，正好当首屏加载）
            .task(id: filter) { await load() }
            .sheet(item: $picked) { o in
                OrderDetailView(order: o) { Task { await load() } }
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

    private func rowView(_ o: OrderItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(o.planName.isEmpty ? o.plan : o.planName)
                        .font(.callout.weight(.semibold))
                    Chip(text: o.statusLabel, tint: Tone.color(Tone.forOrder(o.status)))
                }
                Text(o.orderNo).font(.caption2.monospaced()).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(Fmt.money(o.amount)).font(.caption).foregroundStyle(.primary)
                    if !o.deviceCode.isEmpty {
                        Text(o.deviceCode).font(.caption2.monospaced())
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.time(o.createdAt)).font(.caption2.monospacedDigit())
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
            stats = DemoData.orderStats
            rows = DemoData.orders.filter { filter.isEmpty || $0.status == filter }
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/order/list/all", query: ["status": filter])
            stats = r.dict("stats")
            rows = r.list("rows").map { OrderItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}

/// 订单详情 + 三个操作（确认到账发码 / 取消 / 删除）。
struct OrderDetailView: View {
    let order: OrderItem
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false
    @State private var issued = ""
    @State private var askDays = false
    @State private var days = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("订单") {
                    KVRow(k: "单号", v: order.orderNo, mono: true)
                    KVRow(k: "套餐", v: order.planName.isEmpty ? order.plan : order.planName)
                    KVRow(k: "金额", v: Fmt.money(order.amount))
                    KVRow(k: "天数", v: "\(order.days)")
                    KVRow(k: "状态", v: order.statusLabel)
                }
                Section("客户") {
                    KVRow(k: "设备码", v: order.deviceCode, mono: true)
                    KVRow(k: "联系方式", v: order.contact)
                    KVRow(k: "备注", v: order.note)
                    KVRow(k: "IP", v: order.ip, mono: true)
                }
                Section("时间") {
                    KVRow(k: "下单", v: Fmt.time(order.createdAt))
                    KVRow(k: "付款", v: Fmt.time(order.paidAt))
                    KVRow(k: "发码", v: Fmt.time(order.doneAt))
                    KVRow(k: "操作人", v: order.doneBy)
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
                        days = ""
                        askDays = true
                    } label: {
                        Label("确认到账 / 重新发码", systemImage: "checkmark.seal.fill")
                    }
                    .disabled(busy)

                    Button {
                        Task { await act { try await API.shared.post("/api/order/\(order.id)/cancel") } }
                    } label: {
                        Label("取消订单", systemImage: "xmark.circle")
                    }
                    .disabled(busy)

                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除订单", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }
            .navigationTitle("订单详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("发码天数", isPresented: $askDays) {
                TextField("留空 = 用套餐自带的 \(order.days) 天", text: $days)
                    .keyboardType(.numberPad)
                Button("取消", role: .cancel) {}
                Button("确认发码") { Task { await confirm() } }
            } message: {
                Text("会给这台设备生成解锁码并把授权设为「今天起 N 天」。已发过码的订单也能用它顺延。")
            }
            .confirmationDialog("确定删除这条订单？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { Task { await del() } }
                Button("取消", role: .cancel) {}
            }
            .overlay { if busy { ProgressView().padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        }
    }

    private func confirm() async {
        var body: [String: Any] = [:]
        if let n = Int(days.trimmingCharacters(in: .whitespaces)), n > 0 { body["days"] = n }
        await act(okWord: "已发码") { try await API.shared.post("/api/order/\(order.id)/confirm", body: body) }
    }

    private func del() async {
        await act(okWord: "已删除") { try await API.shared.delete("/api/order/\(order.id)") }
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
