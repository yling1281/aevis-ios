import SwiftUI
import UIKit

/// 崩溃现场：App 崩了之后自己传上来的那份东西。
///
/// 错误码是 App 那边**算出来的不是随机的**（版本 + 崩前最后一个动作），
/// 所以同一个故障每次都是同一个码 —— 好几个用户报同一个码，
/// 就是卡在同一处，优先修它（右边那个 `×N` 就是报了几次）。
struct DiagSection: View {
    @EnvironmentObject private var store: AdminStore
    @State private var open: DiagReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "崩溃现场（错误码）")

            if store.diag.isEmpty {
                AdminCard { AdminEmpty(text: "还没有崩过 —— 或者崩了但没传上来。") }
            } else {
                AdminCard {
                    ForEach(Array(store.diag.enumerated()), id: \.element.id) { index, item in
                        Button {
                            open = item
                        } label: {
                            row(item, divider: index > 0)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            AdminNote(text: "点开能看到崩之前的最后几十步操作。看不动的时候就挑 ×N 大的那条，"
                     + "那说明很多人卡在同一处。处理完点「标记已反馈」——"
                     + "智能客服会在报过的用户下次说话时告诉他。")
        }
        .sheet(item: $open) { item in
            DiagDetailView(report: item)
                .environmentObject(store)
        }
    }

    private func row(_ item: DiagReport, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: item.codeText,
                subtitle: [item.machine, item.os.map { "iOS " + $0 }, item.version]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                detail: "设备 \(item.deviceId ?? "—")　最后 "
                    + AdminFormat.ago(item.lastAt) + "（\(AdminFormat.when(item.lastAt))）",
                badge: badges(item)
            )
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
    }

    private func badges(_ item: DiagReport) -> (String, Color)? {
        if item.isAnswered { return ("已反馈", AdminSkin.brand) }
        if let count = item.count, count > 1 { return ("×\(count)", AdminSkin.danger) }
        return nil
    }
}

// MARK: - 详情

/// 一条崩溃现场的详情。
///
/// ⚠️ 正文（`body`）是**崩之前那几十步操作**，里面现在也含聊天内容
/// —— 所以后台列表接口默认不带正文，只有点进来才拉一次（`/diag/detail`），
/// 而且**只有管理员这条路能看**（服务端解密在 `require_admin` 之后）。
struct DiagDetailView: View {
    var report: DiagReport

    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryCard
                    bodyCard
                    askersCard
                    feedbackCard
                }
                .padding(16)
                .frame(maxWidth: AdminSkin.pageMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(report.codeText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关掉") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    AdminCopyButton(text: fullReport, label: "复制")
                }
            }
            .task {
                note = report.feedbackNote ?? ""
                await store.loadDiagDetail(code: report.code ?? "", deviceId: report.deviceId ?? "")
            }
        }
    }

    // MARK: 概况

    private var summaryCard: some View {
        AdminCard {
            AdminCardRow(showsDivider: false) {
                AdminLine(
                    title: report.codeText,
                    subtitle: "\(report.machine ?? "—") · iOS \(report.os ?? "—") · 版本 \(report.version ?? "—")",
                    detail: "设备 \(report.deviceId ?? "—")\n"
                        + "第一次 \(AdminFormat.when(report.firstAt))　"
                        + "最后一次 \(AdminFormat.when(report.lastAt))\n"
                        + "共上报 \(report.count ?? 0) 次"
                )
            } trailing: {
                EmptyView()
            }
        }
    }

    // MARK: 现场正文

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "崩之前的最后几十步")
            AdminCard {
                if store.diagDetailLoading {
                    AdminEmpty(text: "读取中…")
                } else if let body = store.openDiag?.body, !body.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines(body).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(line.contains("⚠️") || line.contains("失败")
                                                 ? AdminSkin.danger : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                } else {
                    AdminEmpty(text: "这份没带正文 —— 可能是老版本传的。")
                }
            }
            if let last = AdminFormat.lastLine(store.openDiag?.body).nilIfEmpty {
                AdminNote(text: "最后一步：\(last)")
            }
        }
    }

    private func lines(_ body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: 谁问过

    private var askersCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "谁在群里问过这个码")
            if store.openDiagAskers.isEmpty {
                AdminCard { AdminEmpty(text: "还没有人在群里问过这个码。") }
            } else {
                AdminCard {
                    ForEach(Array(store.openDiagAskers.enumerated()), id: \.element.id) { index, asker in
                        AdminCardRow(showsDivider: index > 0) {
                            AdminLine(
                                title: "QQ \(asker.qq ?? "—")",
                                subtitle: [(asker.nickname ?? "").nilIfEmpty,
                                           asker.groupId.map { "群 " + $0 }].compactMap { $0 }.joined(separator: " · "),
                                detail: "问于 \(AdminFormat.when(asker.askedAt))"
                                    + (asker.isTold ? "　已通知" : "　还没通知")
                            )
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
                AdminNote(text: "标记已反馈之后，机器人会在这些人下次在群里说话时把结果告诉他们。")
            }
        }
    }

    // MARK: 反馈

    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "处理结果")
            AdminCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("跟他说一句（比如：已经修好了，更新到最新版试试）",
                              text: $note, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                    HStack(spacing: 8) {
                        if report.isAnswered {
                            Text("已反馈（\(AdminFormat.when(report.feedbackAt))）")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        AdminMiniButton(title: saving ? "提交中…" : "标记已反馈",
                                        tint: AdminSkin.brand, filled: true) {
                            guard !saving else { return }
                            saving = true
                            Task {
                                await store.markFeedback(code: report.code ?? "", note: note)
                                saving = false
                                dismiss()
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var fullReport: String {
        var out = "【Aevis 崩溃现场】\n错误码 \(report.codeText)\n"
        out += "版本 \(report.version ?? "—") · iOS \(report.os ?? "—") · \(report.machine ?? "—")\n"
        out += "设备 \(report.deviceId ?? "—")\n"
        out += "上报 \(report.count ?? 0) 次　最后 \(AdminFormat.when(report.lastAt))\n"
        if let body = store.openDiag?.body, !body.isEmpty {
            out += "\n—— 崩之前的最后几十步 ——\n" + body
        }
        return out
    }
}

extension String {
    /// 空串在界面上等于「没有」，用它省掉一堆 `isEmpty ? nil : self`。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
