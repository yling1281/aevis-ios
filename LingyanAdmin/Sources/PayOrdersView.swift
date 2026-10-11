import SwiftUI

/// 码支付 · 订单。
///
/// 两段（分段控件切）：
///   · **订单** —— `GET /api/orders`（可搜单号/商户单号/设备码/邮箱，可按状态筛）
///   · **到账流水** —— `GET /api/matches`（监听端抓到的每一笔到账，以及它挂上了哪一单）
///
/// 为什么把这两张放一页：零砚排查「钱到了没发货」时，看的就是
/// **流水有没有认上单** —— 一边是单、一边是钱，切着看最直观。
struct PayOrdersView: View {
    @State private var seg = 0
    @State private var state: LoadState = .idle
    @State private var rawOrders: [[String: Any]] = []
    @State private var rawMatches: [[String: Any]] = []
    @State private var search = ""
    @State private var statusFilter = -1        // -1 = 全部
    @State private var picked: PayRow?

    /// ⚠️ 统一先转成 `[PayRow]` 再进 ForEach。
    ///    不能写 `ForEach(raws, id: \.s("order_no"))` ——
    ///    **键路径里不能调方法**（`\.[...]` 只能取属性 / 下标），那样写编不过。
    private var orderRows: [PayRow] {
        var rows = rawOrders
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.s("order_no").lowercased().contains(q)
                    || $0.s("merchant_no").lowercased().contains(q)
                    || $0.s("device_code").lowercased().contains(q)
                    || $0.s("email").lowercased().contains(q)
            }
        }
        if statusFilter >= 0 {
            rows = rows.filter { $0.i("status") == statusFilter }
        }
        return rows.map { orderRow($0) }
    }

    private var matchRows: [PayRow] {
        var rows = rawMatches
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            rows = rows.filter {
                $0.s("order_no").lowercased().contains(q)
                    || $0.s("flow").lowercased().contains(q)
                    || $0.s("remark").lowercased().contains(q)
                    || $0.s("account").lowercased().contains(q)
            }
        }
        return rows.map { matchRow($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $seg) {
                    Text("订单 \(orderRows.count)").tag(0)
                    Text("到账流水 \(matchRows.count)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                StateBanner(state: state) { Task { await load() } }

                List {
                    if seg == 0 {
                        if orderRows.isEmpty {
                            Text(state.isLoading ? "正在加载…" : "没有符合条件的订单")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(orderRows) { row in
                            Button {
                                picked = row
                            } label: {
                                PayRowCell(row: row)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        if matchRows.isEmpty {
                            Text(state.isLoading ? "正在加载…" : "没有符合条件的流水")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(matchRows) { row in
                            NavigationLink {
                                PayDetailView(row: row)
                            } label: {
                                PayRowCell(row: row)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("码支付订单")
            .searchable(text: $search, prompt: "搜单号 / 商户单号 / 设备码 / 流水")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("全部状态") { statusFilter = -1 }
                        Button("待支付") { statusFilter = 0 }
                        Button("已支付") { statusFilter = 1 }
                        Button("已关闭") { statusFilter = 2 }
                        Button("已过期") { statusFilter = 5 }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $picked) { row in
                NavigationStack {
                    PayDetailView(row: row)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("关闭") { picked = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: - 行数据

    private func orderRow(_ o: [String: Any]) -> PayRow {
        let st = o.i("status")
        let real = o.d("real_amount")
        return PayRow(
            id: o.s("order_no"),
            title: o.s("order_no"),
            sub: "\(payTypeText(o.s("pay_type"))) · \(o.s("channel_no")) · \(o.s("subject"))",
            right: Fmt.money(real > 0 ? real : o.d("amount")),
            tone: payStatusTone(st),
            chip: payStatusText(st),
            chipTint: Tone.color(payStatusTone(st)),
            detail: [
                ("平台单号", o.s("order_no")),
                ("商户单号", o.s("merchant_no")),
                ("支付方式", payTypeText(o.s("pay_type"))),
                ("通道", o.s("channel_no")),
                ("应收", Fmt.money(o.d("amount"))),
                ("挂牌价", Fmt.money(o.d("base_amount"))),
                ("实收", Fmt.money(real)),
                ("认单码", o.s("remark_code")),
                ("设备码", o.s("device_code")),
                ("邮箱", o.s("email")),
                ("状态", payStatusText(st)),
                ("回调", notifyText(o)),
                ("下单时间", o.s("created_at")),
                ("支付时间", o.s("paid_at")),
            ]
        )
    }

    private func matchRow(_ m: [String: Any]) -> PayRow {
        let st = m.s("state")
        return PayRow(
            id: "\(m.i("id"))",
            title: "\(m.s("account")) 收到 " + Fmt.money(m.d("amount")),
            sub: Fmt.time(m.s("happen_at"))
                 + (m.s("remark").isEmpty ? "" : " · 备注「\(m.s("remark"))」"),
            right: payMatchText(st),
            tone: payMatchTone(st),
            chip: payMatchText(st),
            chipTint: Tone.color(payMatchTone(st)),
            detail: [
                ("收款账号", m.s("account")),
                ("金额", Fmt.money(m.d("amount"))),
                ("流水号", m.s("flow")),
                ("到账时间", m.s("happen_at")),
                ("付款备注", m.s("remark")),
                ("挂上的单", m.s("order_no")),
                ("状态", payMatchText(st)),
                ("通道 id", "\(m.i("channel_id"))"),
                ("登记时间", m.s("created_at")),
            ]
        )
    }

    private func notifyText(_ o: [String: Any]) -> String {
        if o.i("notify_state") == 1 { return "成功" }
        if o.i("notify_times") > 0 { return "待重试（\(o.i("notify_times")) 次）" }
        return "未发"
    }

    // MARK: - 取数

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            rawOrders = PayDemo.orders
            rawMatches = PayDemo.matches
            state = .done
            return
        }
        do {
            if seg == 0 {
                let r = try await PayAPI.shared.get("/api/orders", query: ["limit": "300"])
                rawOrders = r.list("items")
            } else {
                let r = try await PayAPI.shared.get("/api/matches", query: ["limit": "300"])
                rawMatches = r.list("items")
            }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
