import SwiftUI

/// 对话日志（2.8 P2）：`GET /v1/chat/logs?cursor&limit`。
/// 接口未上线 / 没有记录时显示「暂无数据」，**不生成本地假对话**。
/// 第一页走硬缓存离线兜底，翻页只走网络（cursor 是会话状态，缓存下来会错页）。
struct ChatLogsView: View {
    @EnvironmentObject private var session: Session

    @State private var rows: [GrowthAPI.ChatLogEntry] = []
    @State private var nextCursor: String? = nil
    @State private var loading = false
    @State private var loaded = false
    @State private var tip = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if !rows.isEmpty {
                    ForEach(rows) { row in logRow(row) }
                    if nextCursor != nil {
                        Button { Task { await loadMore() } } label: {
                            HStack(spacing: 6) {
                                if loading { ProgressView().controlSize(.mini) }
                                Text(loading ? "加载中…" : "加载更多")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AE.accent)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(AE.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(loading)
                    }
                } else if loaded {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 30))
                            .foregroundStyle(AE.textSecondary)
                        Text("暂无数据")
                            .font(.system(size: 13))
                            .foregroundStyle(AE.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }

                if !tip.isEmpty {
                    Text(tip).font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                }
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(Color.clear)
        .navigationTitle("对话日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func logRow(_ entry: GrowthAPI.ChatLogEntry) -> some View {
        let isUser = entry.role == "user"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(isUser ? "我" : "助手")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isUser ? AE.brandPurple : AE.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(isUser ? AE.brandLilac : AE.accentSoft, in: Capsule())
                if !entry.createdAt.isEmpty {
                    Text(entry.createdAt)
                        .font(.system(size: 10))
                        .foregroundStyle(AE.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Text(entry.content)
                .font(.system(size: 13))
                .foregroundStyle(AE.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin, tintOpacity: 0.16)
        .shadow(color: AE.shadowColor, radius: 10, y: 4)
    }

    // MARK: - 数据

    private func load() async {
        guard !loading else { return }
        await MainActor.run { loading = true }
        let result = await GrowthAPI.chatLogs(cursor: nil, token: session.token, limit: 20)
        await MainActor.run {
            rows = result.rows
            nextCursor = result.nextCursor
            loading = false
            loaded = true
        }
    }

    private func loadMore() async {
        guard !loading, let cursor = nextCursor else { return }
        await MainActor.run { loading = true }
        let result = await GrowthAPI.chatLogs(cursor: cursor, token: session.token, limit: 20)
        await MainActor.run {
            if !result.rows.isEmpty {
                rows.append(contentsOf: result.rows)
            } else {
                nextCursor = nil
            }
            nextCursor = result.nextCursor
            loading = false
            loaded = true
            if result.rows.isEmpty { showTip("没有更多了") }
        }
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
