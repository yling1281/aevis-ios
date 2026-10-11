import SwiftUI

/// 码支付 · 财务。
///
/// 数据 `GET /api/finance?days=N` → 每日一笔 + 按支付方式汇总。
/// 柱状图是**手画的**（`GeometryReader` + `RoundedRectangle`）——
/// 不引 `Charts` 框架：这台流水线是「能少一个依赖就少一个」，
/// 而且 14 根柱子用不着那么重的东西。
struct PayFinanceView: View {
    @State private var days = 14
    @State private var state: LoadState = .idle
    @State private var daily: [[String: Any]] = []
    @State private var byType: [String: Any] = [:]
    @State private var total: Double = 0

    private var maxAmount: Double {
        max(daily.map { $0.d("amount") }.max() ?? 0, 1)
    }

    private var todayRow: [String: Any] {
        daily.last ?? [:]
    }

    private var orderCount: Int {
        daily.reduce(0) { $0 + $1.i("count") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if AppConfig.isDemo {
                        Text("演示数据（-demo 启动，不连服务器）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    StateBanner(state: state) { Task { await load() } }

                    Picker("", selection: $days) {
                        Text("近 7 天").tag(7)
                        Text("近 14 天").tag(14)
                        Text("近 30 天").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: days) { _ in
                        Task { await load() }
                    }

                    HStack(spacing: 10) {
                        BigStat(label: "今日", value: Fmt.moneyGrouped(todayRow.d("amount")),
                                icon: "yensign.circle", tint: .red)
                        BigStat(label: "区间合计", value: Fmt.moneyGrouped(total),
                                icon: "sum", tint: .purple)
                        BigStat(label: "笔数", value: "\(orderCount)",
                                icon: "number", tint: .blue)
                    }

                    // ---- 按支付方式 ----
                    PayCard(title: "按支付方式") {
                        KVRow(k: "微信", v: Fmt.moneyGrouped(byType.d("wechat")))
                        KVRow(k: "支付宝", v: Fmt.moneyGrouped(byType.d("alipay")))
                    }

                    // ---- 柱状图 ----
                    PayCard(title: "每日收款") {
                        if daily.isEmpty {
                            Text("这一段时间没有已支付的订单")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            GeometryReader { geo in
                                let n = max(daily.count, 1)
                                let gap: CGFloat = 3
                                let w = max((geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n), 2)
                                HStack(alignment: .bottom, spacing: gap) {
                                    ForEach(Array(daily.enumerated()), id: \.offset) { _, d in
                                        let h = max(geo.size.height * CGFloat(d.d("amount") / maxAmount), 2)
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.red.opacity(0.75))
                                            .frame(width: w, height: h)
                                    }
                                }
                                .frame(width: geo.size.width, height: geo.size.height,
                                       alignment: .bottomLeading)
                            }
                            .frame(height: 110)
                            HStack {
                                Text(Fmt.day(daily.first?.s("date") ?? "")).font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(Fmt.day(daily.last?.s("date") ?? "")).font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // ---- 每日明细 ----
                    PayCard(title: "每日明细") {
                        ForEach(Array(daily.reversed().enumerated()), id: \.offset) { _, d in
                            HStack {
                                Text(Fmt.day(d.s("date"))).font(.footnote.monospacedDigit())
                                Spacer()
                                Text("\(d.i("count")) 笔")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(Fmt.money(d.d("amount")))
                                    .font(.footnote.monospacedDigit())
                                    .frame(width: 84, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("码支付财务")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            daily = PayDemo.finance.list("daily")
            byType = PayDemo.finance.dict("by_type")
            total = PayDemo.finance.d("total")
            state = .done
            return
        }
        do {
            let r = try await PayAPI.shared.get("/api/finance", query: ["days": "\(days)"])
            daily = r.list("daily")
            byType = r.dict("by_type")
            total = r.d("total")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
