import SwiftUI

/// 概览：服务端统计 + 当前 Key 信息。
struct OverviewView: View {
    @ObservedObject private var cfg = AppConfig.shared

    @State private var state: LoadState = .idle
    @State private var stats: [String: Any] = [:]
    @State private var cards: [String: Any] = [:]
    @State private var me: [String: Any] = [:]
    /// `/api/v1/stats` 的**原始响应**。`server_time` 在这一层，
    /// 不在 `stats` 子对象里 —— 直接去 stats 里取会永远是空的。
    @State private var rawStats: [String: Any] = [:]
    @State private var showSettings = false

    private var labels: [(String, String, String, Color)] {
        [
            ("用户", "\(stats.i("users"))", "person.2.fill", .blue),
            ("素材", "\(stats.i("materials"))", "photo.on.rectangle.angled", .indigo),
            ("设备", "\(stats.i("devices"))", "desktopcomputer", .teal),
            ("未用卡密", "\(cards.i("unused"))", "creditcard", .orange),
            ("已绑卡密", "\(cards.i("bound"))", "checkmark.seal.fill", .green),
            ("今日新卡", "\(cards.i("today"))", "calendar", .pink),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if AppConfig.isDemo {
                        Text("演示数据（-demo 启动，不连服务器）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    StateBanner(state: state) { Task { await load() } }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10),
                                        GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(labels, id: \.0) { item in
                            BigStat(label: item.0, value: item.1, icon: item.2, tint: item.3)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前 Key").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        KVRow(k: "名称", v: me.s("name"))
                        KVRow(k: "权限", v: me.strings("scopes").joined(separator: " / "))
                        KVRow(k: "备注", v: me.s("note"))
                        KVRow(k: "创建于", v: Fmt.time(me.s("created_at")))
                        KVRow(k: "服务器", v: cfg.baseURL, mono: true)
                        KVRow(k: "服务端时间", v: Fmt.time(rawStats.s("server_time")))
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))

                    Text("提示：这页所有数据都是只读的，改数据要去电脑上的管理后台。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("概览")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            me = DemoData.me
            rawStats = DemoData.stats
            stats = rawStats.dict("stats")
            cards = stats.dict("cards")
            state = .done
            return
        }
        do {
            me = try await API.shared.get("/api/v1/me")
            let rStats = try await API.shared.get("/api/v1/stats")
            rawStats = rStats
            stats = rStats.dict("stats")
            cards = stats.dict("cards")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
