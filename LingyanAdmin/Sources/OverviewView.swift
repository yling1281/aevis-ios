import SwiftUI

/// 总览：后台首页。数据来自 4 个管理端点，挨个拉齐。
struct OverviewView: View {
    @ObservedObject private var cfg = AppConfig.shared

    @State private var state: LoadState = .idle
    @State private var audit: [String: Any] = [:]
    @State private var devStats: [String: Any] = [:]
    @State private var cardStats: [String: Any] = [:]
    @State private var orderStats: [String: Any] = [:]
    @State private var showSettings = false
    @State private var showAudit = false
    @State private var showApi = false

    private var today: [String: Any] { audit.dict("today") }

    private var cards: [(String, String, String, Color)] {
        [
            ("在线设备", "\(devStats.i("online"))", "bolt.fill", .teal),
            ("用户", "\(audit.i("users_total"))", "person.2.fill", .blue),
            ("待授权", "\(devStats.i("pending"))", "hourglass", .orange),
            ("已授权", "\(devStats.i("active"))", "checkmark.seal.fill", .green),
            ("未用卡密", "\(cardStats.i("unused"))", "creditcard", .indigo),
            ("待处理单", "\(orderStats.i("pending"))", "tray.full", .pink),
            ("今日收入", Fmt.moneyGrouped(orderStats.d("income_today")), "yensign.circle", .red),
            ("今日登录", "\(today.i("logins_ok"))", "arrow.right.to.line", .purple),
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

                    // ---- 登录概况 ----
                    card("今日登录") {
                        KVRow(k: "成功", v: "\(today.i("logins_ok"))")
                        KVRow(k: "失败", v: "\(today.i("logins_fail"))")
                        KVRow(k: "活跃账号", v: "\(today.i("users"))")
                        KVRow(k: "独立 IP", v: "\(today.i("ips"))")
                        KVRow(k: "已封 IP", v: "\(audit.list("blocked").count)")
                    }

                    // ---- 收入 ----
                    card("收款") {
                        KVRow(k: "累计", v: Fmt.moneyGrouped(orderStats.d("income")))
                        KVRow(k: "今日", v: Fmt.moneyGrouped(orderStats.d("income_today")))
                        KVRow(k: "今日订单", v: "\(orderStats.i("today"))")
                        KVRow(k: "待处理", v: "\(orderStats.i("pending"))")
                        KVRow(k: "已发码", v: "\(orderStats.i("done"))")
                    }

                    // ---- 今日活跃 TOP ----
                    let top = audit.list("top_today")
                    if !top.isEmpty {
                        card("今日活跃 TOP") {
                            ForEach(Array(top.prefix(8).enumerated()), id: \.offset) { _, r in
                                HStack {
                                    Text(r.s("username"))
                                        .font(.footnote)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(r.i("hits")) 次")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(Fmt.time(r.s("last_seen")))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    card("当前登录") {
                        KVRow(k: "账号", v: cfg.username)
                        KVRow(k: "身份", v: cfg.roleText)
                        KVRow(k: "服务器", v: cfg.baseURL, mono: true)
                    }

                    Text(audit.s("rate_limit_note"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("总览")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showAudit = true } label: {
                            Label("审计日志", systemImage: "list.bullet.rectangle")
                        }
                        Button { showApi = true } label: {
                            Label("对外 API", systemImage: "link")
                        }
                        Button { showSettings = true } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showAudit) { AuditView() }
            .sheet(isPresented: $showApi) { ApiKeysView() }
        }
    }

    /// 统一的小卡片容器
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
            audit = DemoData.audit
            devStats = DemoData.deviceStats
            cardStats = DemoData.cardStats
            orderStats = DemoData.orderStats
            state = .done
            return
        }
        do {
            // 串行拉四个端点。故意不用 async let —— 少写一种并发语法，就少一种云端白跑一轮的可能。
            let ra = try await API.shared.get("/api/audit/overview")
            let rd = try await API.shared.get("/api/device/list")
            let rc = try await API.shared.get("/api/card/list")
            let ro = try await API.shared.get("/api/order/list/all")
            audit = ra
            devStats = rd.dict("stats")
            cardStats = rc.dict("stats")
            orderStats = ro.dict("stats")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
