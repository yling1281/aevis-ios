import SwiftUI
import UIKit

/// 解锁码 —— **解锁软件源**用的（收到钱才给）。
///
/// ⚠️ 跟「注册码」**不是一回事**（旁边那一块）：
///   · 注册码 = 注册账号用，免费的，群里机器人自动发；
///   · 解锁码 = 解锁软件源用，**收到钱才给**，就是这一页。
///
/// 拿了码的人这样做：源地址后面加 `?code=这张码` 重新添加一次源，
/// 源里的 App 才会出来；**下载安装包也要带这张码**（IPA 直链已经封了）。
///
/// 故意**不做「一码一人」**：同一个人换设备、重装都得能再用，
/// 所以只记他用了几次、从哪个 IP 用的 —— 有人到处传，你点「作废」。
struct UnlockSection: View {
    @EnvironmentObject private var store: AdminStore

    @State private var count = 1
    @State private var note = ""
    @State private var price = "12"
    @State private var fresh: [String] = []
    /// 等确认作废的那张码（作废会连设备一起撤，是个不可逆动作）。
    @State private var disabling: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminFold("生成解锁码", key: "section.unlock.new") {
                issueCard
                if !fresh.isEmpty { freshCard }
            }

            if let stats = store.unlockStats, !store.unlockCodes.isEmpty {
                AdminCard {
                    HStack(spacing: 0) {
                        AdminStatCell(label: "总数", value: stats.total)
                        AdminStatCell(label: "用过", value: stats.used)
                        AdminStatCell(label: "已作废", value: stats.disabled)
                    }
                }
            }

            AdminFold("解锁码", key: "section.unlock.list", count: store.unlockCodes.count) {
                if store.unlockCodes.isEmpty {
                    AdminCard {
                        AdminEmpty(text: store.loading
                                   ? "读取中…"
                                   : "还没有解锁码。上面「生成」一张，发给付过钱的人。")
                    }
                } else {
                    AdminCard {
                        ForEach(Array(store.unlockCodes.enumerated()), id: \.offset) { index, item in
                            row(item, divider: index > 0)
                        }
                    }
                }
            }

            AdminNote(text: "作废是不可逆的，而且会把用这张码解锁过的设备一起撤掉 ——"
                     + "只标记不撤的话会变成最气人的半死状态：装包工具里看得到 App，"
                     + "一点下载就失败。")
        }
        .alert("确认作废这张码？", isPresented: disablingBinding) {
            Button("取消", role: .cancel) { disabling = nil }
            Button("作废", role: .destructive) {
                guard let code = disabling else { return }
                disabling = nil
                Task { await store.setUnlockDisabled(code, disabled: true) }
            }
        } message: {
            Text("用它解锁过的设备会一起被撤掉，那些人要重新找你要码。\n码：\(disabling ?? "")")
        }
    }

    private var disablingBinding: Binding<Bool> {
        Binding(
            get: { disabling != nil },
            set: { if !$0 { disabling = nil } }
        )
    }

    private var issueCard: some View {
        AdminCard {
            VStack(alignment: .leading, spacing: 11) {
                Stepper(value: $count, in: 1...50) {
                    Text("\(count) 张")
                        .font(.system(size: 15, weight: .medium))
                }
                TextField("买家的 QQ / 邮箱（对账用，可留空）", text: $note)
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                TextField("成交价，如 12", text: $price)
                    .font(.system(size: 14))
                    .keyboardType(.decimalPad)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Button {
                    let wanted = count
                    let why = note
                    let howMuch = price
                    Task {
                        let made = await store.issueUnlockCodes(
                            count: wanted, note: why, price: howMuch)
                        if !made.isEmpty {
                            fresh = made
                            note = ""
                        }
                    }
                } label: {
                    Text(store.busy ? "生成中…" : "生成解锁码")
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
                    Text("刚生成的 \(fresh.count) 张")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    AdminCopyButton(text: fresh.joined(separator: "\n"), label: "全部复制")
                }
                ForEach(fresh, id: \.self) { code in
                    HStack(spacing: 8) {
                        Text(code)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        AdminCopyButton(text: code)
                    }
                }
                Text("发给他的时候记得说清楚：源地址后面加 ?code=这张码 重新添加一次源。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private func row(_ item: AdminUnlockCode, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: item.code ?? "—",
                subtitle: (item.note?.isEmpty == false ? item.note! : "（没写备注）")
                    + (item.price?.text.isEmpty == false ? "　·　\(item.price!.text) 元" : ""),
                detail: usageText(item),
                badge: item.isDisabled ? ("已作废", AdminSkin.danger)
                     : (item.isUsed ? ("用过 \(item.uses ?? 0) 次", AdminSkin.brand) : nil)
            )
        } trailing: {
            HStack(spacing: 6) {
                if let code = item.code {
                    AdminCopyButton(text: code)
                    AdminMiniButton(
                        title: item.isDisabled ? "恢复" : "作废",
                        tint: item.isDisabled ? AdminSkin.brand : AdminSkin.danger
                    ) {
                        if item.isDisabled {
                            Task { await store.setUnlockDisabled(code, disabled: false) }
                        } else {
                            // 作废是不可逆的（还连设备一起撤）→ 必须先问一句
                            disabling = code
                        }
                    }
                }
            }
        }
    }

    /// 「首次使用 … · IP …」或者「发出于 …」。
    private func usageText(_ item: AdminUnlockCode) -> String {
        guard item.isUsed else { return "发出于 " + AdminFormat.when(item.issuedAt) }
        var line = "首次使用 " + AdminFormat.when(item.firstUse)
            + "　·　IP " + (item.usedIp?.isEmpty == false ? item.usedIp! : "?")
        if let ua = item.usedUa, !ua.isEmpty {
            line += "\n" + ua
        }
        return line
    }
}
