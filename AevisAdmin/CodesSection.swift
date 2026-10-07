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
    /// ⭐ 2026-10-07：有效期。0 = 永久（老口径）；86400 = 一天体验（注册后 24h 自动失效）。
    @State private var duration = 0
    @State private var fresh: [String] = []

    // ⚠️ 原来这儿有个 `usedCount`（算用了多少张）。标题交给 `AdminFold` 之后
    //    那一行标题没有了，它就没人用了 —— **当场删掉**，别留死代码
    //    （不留的话下次有人以为它还在某处显示着）。

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminFold("发注册码", key: "section.codes.new") {
                issueCard
                if !fresh.isEmpty { freshCard }
            }
            AdminNote(text: "码是一次性的，一人一码，用过就不能再用。"
                     + "删码只删这一张，不影响已经注册的账号。"
                     + "（`n` 键在码上面写着被哪个邮箱用掉了。）")

            AdminFold("注册码", key: "section.codes.list", count: store.codes.count) {
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
                // ⭐ 2026-10-07：可选"有效期"。永久 = 老口径；一天 = 体验（注册后 24h 自动失效）。
                Picker("有效期", selection: $duration) {
                    Text("永久").tag(0)
                    Text("一天").tag(86400)
                }
                .pickerStyle(.segmented)
                Button {
                    let wanted = count
                    let why = note
                    let howLong = duration
                    Task {
                        let made = await store.issueCodes(count: wanted, note: why, duration: howLong)
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
                    + (code.isTrial ? "一天体验　" : "永久　")
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
