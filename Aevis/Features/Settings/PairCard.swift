import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「配对电脑版」设置卡 —— 生态第一期（D1）。
///
/// 会话列表右上角那个「+」也能直接扫码（微信的加号在同一位置），
/// 但**这张卡是"总得有地方能管它"的那一处**：手输 6 位码的兜底、
/// 已配对的电脑列表、以及解除配对，都在这里。
///
/// ⚠️ 为什么不把"配过哪几台"放到服务器上：服务器上那个 `/pair/list` 要管理凭证，
///    那是电脑端查状态用的。手机上这张列表**只存本机**（见 `PairClient.paired`）。
struct PairCard: View {

    /// 打开哪一屏（`nil` = 没开）。**两个按钮都走 `PairScanView`** ——
    /// 授权的逻辑只此一份，卡片这边不自己发请求。
    @State private var sheet: PairScanView.Mode?
    @State private var working = false
    @State private var note: String?
    @State private var problem: String?
    @State private var reachable: Bool?
    @State private var paired: [PairClient.PairedPC] = []
    @State private var revokeTarget: PairClient.PairedPC?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("配对电脑版")

            serverRow
            rule
            actionRow

            if !paired.isEmpty {
                rule
                pairedList
            }

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let problem {
                rule
                Text(problem)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            explain

            rule
            // ⭐ 显示**实际在用的那台**：局域网直连时是电脑自己的地址
            //    （`192.168.x.x:9100`），公网配对才是腾讯云那台。
            //    这里要是钉死写 `currentBase`，用户明明连的是家里的电脑，
            //    界面上却写着别人的服务器 —— 出问题时会把人带去错误的方向。
            Text("配对服务器：\(paired.first?.base ?? PairClient.currentBase)")
                .font(.aevis(10.5).monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .task { await refresh() }
        .sheet(item: $sheet) { mode in
            PairScanView(mode: mode)
        }
        .onChange(of: sheet) { _, now in
            // 那一屏里可能授权成功了 —— 关掉就要刷新列表，
            // 否则用户看到的是"刚刚明明成了，回来还是空的"。
            if now == nil { Task { await refresh() } }
        }
        .confirmationDialog(
            "解除和「\(revokeTarget?.name ?? "")」的配对？",
            isPresented: Binding(
                get: { revokeTarget != nil },
                set: { if !$0 { revokeTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("解除", role: .destructive) {
                if let target = revokeTarget { Task { await revoke(target) } }
            }
            Button("取消", role: .cancel) { revokeTarget = nil }
        } message: {
            Text("那台电脑下次打开要重新扫码。手机上你的聊天记录不受影响。")
        }
    }

    // MARK: - 行

    private var serverRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("服务器")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                Text(statusText)
                    .font(.aevis(13.5))
                    .foregroundStyle(reachable == true ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if working || reachable == nil {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(reachable == true ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                problem = nil
                note = nil
                sheet = .scan
            } label: {
                Text("扫电脑上的码")
                    .font(.aevis(15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppSettings.shared.accentColor)
            .disabled(!QRScannerView.isAvailable)

            Spacer(minLength: 8)

            Button {
                problem = nil
                note = nil
                sheet = .manual
            } label: {
                Text(QRScannerView.isAvailable ? "手输配对码" : "手输配对码（相机不可用）")
                    .font(.aevis(14))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AppSettings.shared.accentColor)
            .disabled(working)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var pairedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("已经配对的电脑")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 4)

            ForEach(Array(paired.enumerated()), id: \.element.id) { index, pc in
                if index > 0 { rule }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pc.name)
                            .font(.aevis(14))
                        Text("配对于 \(stamp(pc.at))")
                            .font(.aevis(11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        revokeTarget = pc
                    } label: {
                        Text("解除")
                            .font(.aevis(13))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("电脑版第一次打开会显示一张二维码。用它扫一下，"
                 + "那台电脑就登上了你这台手机里的 Aevis 账号 —— "
                 + "手机上聊过的事，电脑那边接得上。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 13)
                .padding(.bottom, 13)

            Text("⚠️ 授权 = 把那台电脑交给你现在用的她。"
                 + "屏幕上出现你不认识的二维码时，别授权。")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 13)
        }
    }

    private var statusText: String {
        if working { return "检查中…" }
        if reachable == nil { return "还没查" }
        return reachable == true ? "连得上" : "连不上（不影响 App 其他功能）"
    }

    private func stamp(_ at: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: at))
    }

    // MARK: - 动作

    @MainActor
    private func refresh() async {
        paired = PairClient.paired
        working = true
        reachable = await PairClient.ping()
        working = false
    }

    @MainActor
    private func revoke(_ pc: PairClient.PairedPC) async {
        note = nil
        problem = nil
        working = true
        await PairClient.revoke(session: pc.session)
        paired = PairClient.forget(session: pc.session)
        // ⭐ 解除的这台正好是通道连着的 → 顺手把通道也关了，
        //    别让它继续挂在那台已经"不再是我们的电脑"的机器上。
        if PairChannel.shared.currentSession == pc.session {
            PairChannel.shared.stop()
        }
        working = false
        note = "已经解除和「\(pc.name)」的配对。"
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
