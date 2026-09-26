import SwiftUI
import UIKit

/// 注册码：手动发码 + 看谁用掉了。
///
/// 说明一下这里和「QQ 机器人发注册码」的分工：群里的机器人是**自动**发码，
/// 这一页是**手动**给（比如有人私下找你买、或者要补给谁）。
/// 两边写的是同一张 `invite_codes` 表，所以这里也能看到机器人发出去的码。
struct CodesSection: View {
    @EnvironmentObject private var store: AdminStore

    @State private var count = 1
    @State private var note = ""
    @State private var fresh: [String] = []

    private var usedCount: Int { store.codes.filter(\.isUsed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "发注册码")
            issueCard
            if !fresh.isEmpty { freshCard }
            AdminNote(text: "码是一次性的，一人一码，用过就不能再用。"
                     + "删码只删这一张，不影响已经注册的账号。"
                     + "（`n` 键在码上面写着被哪个邮箱用掉了。）")

            AdminSectionTitle(text: "注册码（共 \(store.codes.count)，已用 \(usedCount)）")
            if store.codes.isEmpty {
                AdminCard { AdminEmpty(text: store.loading ? "读取中…" : "还没有发过码。") }
            } else {
                AdminCard {
                    ForEach(Array(store.codes.enumerated()), id: \.element.id) { index, code in
                        row(code, divider: index > 0)
                    }
                }
            }
        }
    }

    private var issueCard: some View {
        AdminCard {
            VStack(alignment: .leading, spacing: 11) {
                Stepper(value: $count, in: 1...100) {
                    Text("\(count) 张")
                        .font(.system(size: 15, weight: .medium))
                }
                TextField("备注（给谁 / 为什么，可留空）", text: $note)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Button {
                    let wanted = count
                    let why = note
                    Task {
                        let made = await store.issueCodes(count: wanted, note: why)
                        if !made.isEmpty {
                            fresh = made
                            note = ""
                        }
                    }
                } label: {
                    Text(store.busy ? "生成中…" : "生成注册码")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AdminSkin.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.busy)
            }
            .padding(14)
        }
    }

    private var freshCard: some View {
        AdminCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("刚发出来的 \(fresh.count) 张")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    AdminCopyButton(text: fresh.joined(separator: "\n"), label: "全部复制")
                }
                ForEach(fresh, id: \.self) { code in
                    Text(code)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("这一块关掉就没了，要发赶紧发（列表里也还能找到）。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
        }
    }

    private func row(_ code: AdminCode, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: code.code ?? "—",
                subtitle: code.isUsed
                    ? "已用 · \(code.usedBy ?? "?")　\(AdminFormat.ago(code.usedAt))"
                    : "未用",
                detail: (code.note?.isEmpty == false ? "备注：\(code.note!)　" : "")
                    + "发于 \(AdminFormat.when(code.issuedAt))",
                badge: code.isUsed ? ("已用", AdminSkin.warn) : nil
            )
        } trailing: {
            AdminMiniButton(title: "删除", tint: AdminSkin.danger) {
                Task { await store.deleteCode(code.code ?? "") }
            }
        }
    }
}
