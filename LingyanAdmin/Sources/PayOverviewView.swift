import SwiftUI

/// 码支付 · 总览。
///
/// 数据来自 `GET /payadmin/api/overview`（一次拿全）。
/// 这张页面回答的是零砚最常问的那几个问题：
/// **现在几条通道活着？今天收了多少？有没有单子卡在待支付？流水有没有认上单？**
struct PayOverviewView: View {
    @ObservedObject private var cfg = PayConfig.shared

    @State private var state: LoadState = .idle
    @State private var data: [String: Any] = [:]
    @State private var busy = ""

    private var cards: [(String, String, String, Color)] {
        [
            ("通道在线", "\(data.i("channels_online"))", "checkmark.circle.fill", .green),
            ("通道掉线", "\(data.i("channels_down"))", "exclamationmark.triangle.fill", .red),
            ("通道总数", "\(data.i("channels"))", "arrow.triangle.branch", .teal),
            ("待支付", "\(data.i("pending"))", "hourglass", .orange),
            ("今日订单", "\(data.i("orders_today"))", "doc.text", .blue),
            ("今日成功", "\(data.i("paid_today"))", "seal.fill", .indigo),
            ("今日收款", Fmt.moneyGrouped(data.d("amount_today")), "yensign.circle", .red),
            ("累计收款", Fmt.moneyGrouped(data.d("amount_total")), "banknote", .purple),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if AppConfig.isDemo {
                        Text("演示数据（-demo 启动，不连服务器）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    StateBanner(state: state) { Task { await load() } }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(cards, id: \.0) { item in
                            BigStat(label: item.0, value: item.1, icon: item.2, tint: item.3)
                        }
                    }

                    // ---- 通道健康 ----
                    card("通道健康") {
                        KVRow(k: "总数", v: "\(data.i("channels"))")
                        KVRow(k: "已启用", v: "\(data.i("channels_on"))")
                        KVRow(k: "在线", v: "\(data.i("channels_online"))")
                        KVRow(k: "掉线", v: "\(data.i("channels_down"))")
                        KVRow(k: "空闲", v: "\(data.i("channels_idle"))")
                    }

                    // ---- 收款 ----
                    card("收款") {
                        KVRow(k: "今日", v: Fmt.moneyGrouped(data.d("amount_today")))
                        KVRow(k: "累计", v: Fmt.moneyGrouped(data.d("amount_total")))
                        KVRow(k: "今日订单", v: "\(data.i("orders_today"))")
                        KVRow(k: "今日成功", v: "\(data.i("paid_today"))")
                        KVRow(k: "订单总数", v: "\(data.i("orders"))")
                    }

                    // ---- 认单 ----
                    card("认单与工单") {
                        KVRow(k: "到账流水", v: "\(data.i("matches"))")
                        KVRow(k: "待支付", v: "\(data.i("pending"))")
                        KVRow(k: "待处理工单", v: "\(data.i("tickets_open"))")
                    }

                    card("当前登录") {
                        KVRow(k: "账号", v: cfg.username)
                        KVRow(k: "服务器", v: cfg.baseURL, mono: true)
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("码支付总览")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { await probeAll() }
                        } label: {
                            Label("测一遍所有通道", systemImage: "waveform.path.ecg")
                        }
                        Button {
                            Task { await pullAll() }
                        } label: {
                            Label("立刻拉一次账单", systemImage: "arrow.down.doc")
                        }
                    } label: {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    .disabled(!busy.isEmpty)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .overlay(alignment: .top) {
                if !busy.isEmpty {
                    Text(busy)
                        .font(.caption2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            data = PayDemo.overview
            state = .done
            return
        }
        do {
            data = try await PayAPI.shared.get("/api/overview")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }

    private func probeAll() async {
        busy = "正在探活所有通道…"
        defer { busy = "" }
        if AppConfig.isDemo {
            Toast.shared.show("通道探活：4 在线 / 1 掉线（演示）")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/channels/probe")
            let items = r.list("items")
            let ok = items.filter { $0.b("ok") }.count
            Toast.shared.show("通道探活：\(ok) 条通 / \(items.count - ok) 条不通")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "探活失败")
        }
    }

    private func pullAll() async {
        busy = "正在拉账单…"
        defer { busy = "" }
        if AppConfig.isDemo {
            Toast.shared.show("拉单：新增 1 条流水、认单 1 笔（演示）")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/matches/pull")
            Toast.shared.show("拉单完成：\(r.i("pulled")) 条通道、新增 \(r.i("added")) 条流水、认单 \(r.i("matched")) 笔")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "拉单失败")
        }
    }
}
