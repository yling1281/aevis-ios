import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「钱包」页 —— 转账 / 红包都从这儿发出去。
///
/// 用户原话（2026-09-29）：
/// 「你弄个假支付功能，就是你这里有钱包，对面那里也有钱包」
/// 「然后支付功能的话，也是气泡」
///
/// ⚠️ **全是本地假数据**（`WalletStore`），不接任何真支付。
///    真钱那套在服务端（支付宝 12 元收款），跟这里没有关系。
struct WalletView: View {

    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var noteText = ""
    @State private var isRedPacket = false
    @State private var note: String?
    @State private var sending = false

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "TA" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    balances
                    picker
                    amountField
                    if !isRedPacket { noteField }
                    sendButton

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    // ⚠️ 拼接出来的字符串**必须包 LocalizedStringKey**，
                    //    否则 Text 走的是 `Text(String)` 那个重载，
                    //    `**加粗**` 不会解析 —— 截图里星号就明晃晃地露着
                    //    （2026-09-29 真栽了，检查器 R17 已补上这条）。
                    Text(LocalizedStringKey("这是**本机上的假钱包** —— 余额和转账都只存在这台手机上，"
                                            + "不接任何真的支付，也不会真的扣谁的钱。"))
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("钱包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 两边的余额

    private var balances: some View {
        HStack(spacing: 12) {
            balanceCard(title: "我的钱包", value: wallet.myBalance, mine: true)
            balanceCard(title: "\(personaName)的钱包", value: wallet.taBalance, mine: false)
        }
    }

    private func balanceCard(title: String, value: Double, mine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
            Text(WalletStore.money(value))
                .font(.aevis(21, weight: .semibold))
                .foregroundStyle(mine ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 16)
    }

    // MARK: - 转账 / 红包

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach([false, true], id: \.self) { red in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isRedPacket = red }
                } label: {
                    Text(red ? "红包" : "转账")
                        .font(.aevis(13, weight: isRedPacket == red ? .semibold : .regular))
                        .foregroundStyle(isRedPacket == red ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(isRedPacket == red ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .aevisGlass(cornerRadius: 14)
    }

    private var amountField: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("金额")
                .font(.aevis(12))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("¥")
                    .font(.aevis(19, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .font(.aevis(19, weight: .medium))
                    .keyboardType(.decimalPad)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            // 微信那种快捷金额
            HStack(spacing: 8) {
                ForEach(WalletStore.quickAmounts, id: \.self) { value in
                    Button {
                        amountText = String(format: "%.2f", value)
                    } label: {
                        Text(Self.shortMoney(value))
                            .font(.aevis(12.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .aevisGlass(cornerRadius: 11)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("附言（可以不写）")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            TextField("说点什么…", text: $noteText, axis: .vertical)
                .lineLimit(1...3)
                .font(.aevis(14.5))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            HStack(spacing: 8) {
                if sending { ProgressView().controlSize(.small) }
                Text(sending ? "发出去…" : (isRedPacket ? "塞进红包" : "转给\(personaName)"))
                    .font(.aevis(15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    // MARK: - 动作

    /// 5.20 显示成 "5.20"，52.00 显示成 "52"（整钱不拖两个零）。
    private static func shortMoney(_ value: Double) -> String {
        let whole = value.rounded()
        if abs(value - whole) < 0.005 { return String(format: "%.0f", whole) }
        return String(format: "%.2f", value)
    }

    private func send() {
        guard !sending else { return }
        let cleaned = amountText.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value > 0 else {
            note = "先填个金额（比如 5.20）。"
            return
        }
        let tail = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sent = wallet.send(amount: value, note: tail)
        guard sent > 0 else {
            note = "钱包里不够 \(WalletStore.money(value)) 了。"
            return
        }

        let info = ChatMessage.Transfer(amount: sent,
                                        note: tail,
                                        accepted: false,
                                        isRedPacket: isRedPacket)
        let id = chat.appendTransfer(info)

        // 隔一拍让"对面收下"—— 这是**假的**，但气泡上那个「待收款」得能变成
        // 「已收款」，不然看起来就像钱转丢了。
        sending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            chat.markTransferAccepted(id)
            sending = false
            dismiss()
        }
    }
}

// MARK: - 聊天气泡

/// 聊天里那条转账 / 红包。微信那种带图标的卡片，不是普通气泡。
struct TransferBubble: View {
    let info: ChatMessage.Transfer
    let isMine: Bool
    var onTap: () -> Void

    private var tint: Color { info.isRedPacket ? Color(red: 0.90, green: 0.28, blue: 0.24) : Color.orange }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 36) }
            Button(action: onTap) { card }
                .buttonStyle(.plain)
            if !isMine { Spacer(minLength: 36) }
        }
    }

    private var card: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color.white.opacity(0.22))
                Image(systemName: info.isRedPacket ? "gift.fill" : "yensign.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.note.isEmpty ? (info.isRedPacket ? "恭喜发财" : "转账") : info.note)
                    .font(.aevis(13.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(info.accepted ? "已收款" : "待收款")
                    .font(.aevis(11))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            Spacer(minLength: 10)

            Text(WalletStore.money(info.amount))
                .font(.aevis(15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: 248, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }
}

// MARK: - 点开看详情

/// 点那条转账气泡进来的详情页。
struct TransferDetailSheet: View {

    let message: ChatMessage

    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @Environment(\.dismiss) private var dismiss

    private var info: ChatMessage.Transfer { message.transfer ?? .init(amount: 0) }
    private var isMine: Bool { message.role == .user }

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "TA" : name
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22))
                    Image(systemName: info.isRedPacket ? "gift.fill" : "yensign.circle.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 68, height: 68)

                Text(WalletStore.money(info.amount))
                    .font(.aevis(30, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(isMine ? "转给\(personaName)" : "\(personaName)转给我")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)

                if !info.note.isEmpty {
                    Text(info.note)
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                Text(info.accepted ? "已收款" : "待收款")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)

                // 别人转给我的、还没收 → 给个「收下」。
                // ⚠️ 只能是**她的转账**：我自己转出去的没有"收下"这回事。
                if !isMine, !info.accepted {
                    Button {
                        wallet.receive(amount: info.amount)
                        chat.markTransferAccepted(message.id)
                        dismiss()
                    } label: {
                        Text("收下")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .aevisGlass(cornerRadius: 15)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 30)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 34)
            .frame(maxWidth: .infinity)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle(info.isRedPacket ? "红包" : "转账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
