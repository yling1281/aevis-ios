import SwiftUI
import UIKit

/// 总览：那八个数字，外加「有什么要处理的」。
///
/// ⭐ 顶上那张待办卡是有意加的 —— 打开 App 先看到"有几件事要动"，
/// 比看到八个总数更有用（总数是给自己看的，待办是"现在该干什么"）。
struct OverviewSection: View {
    @EnvironmentObject private var store: AdminStore

    private var unanswered: [DiagReport] { store.diag.filter { !$0.isAnswered } }
    private var pendingRequests: [DeviceRequest] { store.deviceRequests.filter(\.isPending) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !unanswered.isEmpty || !pendingRequests.isEmpty {
                todoCard
            }

            AdminSectionTitle(text: "总览")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 104), spacing: 9)],
                spacing: 9
            ) {
                ForEach(store.stats?.cells ?? [], id: \.0) { cell in
                    AdminStatCell(label: cell.0, value: cell.1)
                }
            }

            if store.stats == nil {
                AdminCard { AdminEmpty(text: store.loading ? "读取中…" : "没拿到数据，下拉刷新一下。") }
            }

            AdminNote(text: "「今日发信」是注册验证码的发送量 —— 163 免费邮箱每天有上限，"
                     + "烧完了就没人能注册。这个数高了就该看一眼。")

            if let at = store.refreshedAt {
                AdminNote(text: "上次刷新：\(AdminFormat.when(Int(at.timeIntervalSince1970)))")
            }
        }
    }

    private var todoCard: some View {
        AdminCard {
            AdminCardRow(showsDivider: false) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AdminSkin.warn)
                        Text("有事情要处理")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    if !unanswered.isEmpty {
                        Text("· 崩溃现场有 \(unanswered.count) 条还没反馈")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                    if !pendingRequests.isEmpty {
                        Text("· 换机申请有 \(pendingRequests.count) 条待批")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                EmptyView()
            }
        }
    }
}
