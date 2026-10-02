import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 配对电脑版 —— **扫码 / 手输 → 确认 → 授权**，一屏走完。
///
/// 两个入口共用这一份：
///   · 会话列表右上角「+ → 扫一扫 · 配对电脑版」（跟微信的加号在同一位置）
///   · 设置 → 账号与数据 → 配对电脑版（那里开的是 `.manual`，手输 6 位码）
///
/// ⚠️ **别在调用方各自写一遍"扫到之后怎么办"** —— 授权是个有安全含义的动作，
/// 逻辑必须只有一份，改口径时才不会漏掉一个入口。
/// （2026-10-02 就是这么定的：本来 `PairCard` 里也有一份手输逻辑，收进来了。）
struct PairScanView: View {

    /// 打开时先给人看哪一屏。
    enum Mode: String, Identifiable {
        case scan
        case manual

        var id: String { rawValue }
    }

    var mode: Mode = .scan

    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .scanning
    @State private var ticket: PairClient.Ticket?
    @State private var problem: String?
    @State private var gotName = ""
    @State private var gotAlready = false
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    /// 重新发一张「扫码器」用的 —— `QRScannerView` 内部认到一段码就自己停了，
    /// 想再扫必须**换一个实例**（同一个实例不会二次回调）。
    @State private var scanToken = UUID()

    private enum Stage: Equatable {
        case scanning
        case manual
        case confirming
        case working
        case done
        case failed
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .scanning: scanner
                case .manual: manualEntry
                case .confirming: confirm
                case .working: busy
                case .done: done
                case .failed: failed
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                if stage == .failed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("重来") { restart() }
                    }
                }
            }
        }
        .onAppear {
            if mode == .manual { stage = .manual }
        }
    }

    private var title: String {
        switch stage {
        case .scanning: return "扫电脑上的码"
        case .manual: return "手输配对码"
        case .confirming: return "确认授权"
        case .working: return "正在授权…"
        case .done: return "授权成功"
        case .failed: return "没成"
        }
    }

    // MARK: - 各屏

    private var scanner: some View {
        ZStack {
            if QRScannerView.isAvailable {
                QRScannerView { text in handleScanned(text) }
                    .id(scanToken)
                    .ignoresSafeArea(edges: .bottom)

                VStack {
                    Spacer()
                    Text("把电脑上那张二维码放进取景框")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 26)

                    // 相机不认码 / 屏幕太脏 / 码在另一台电脑上 —— 总得留条路
                    Button {
                        problem = nil
                        stage = .manual
                    } label: {
                        Text("扫不了？手输 6 位码")
                            .font(.aevis(13))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 40)
                }
            } else {
                // ⚠️ 用不了相机时**不能只留一片黑**，得给一条能走通的路
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("这台设备用不了相机。")
                        .font(.aevis(15))
                    Button {
                        stage = .manual
                    } label: {
                        Text("手输 6 位配对码")
                            .font(.aevis(15))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 11)
                            .background(AppSettings.shared.accentColor,
                                        in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("电脑版二维码下面有一串 6 位数字，输进来和扫码一样。")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.aevis(28, weight: .medium).monospacedDigit())
                .focused($codeFocused)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .aevisGlass(cornerRadius: 16)
                .onChange(of: code) { _, fresh in
                    // 数字键盘也能粘进别的字符 —— 只留数字、最多 6 位
                    let digits = String(fresh.filter { $0.isNumber }.prefix(6))
                    if digits != fresh { code = digits }
                }

            Text("服务器：\(PairClient.currentBase)")
                .font(.aevis(11).monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let problem {
                Text(problem)
                    .font(.aevis(12.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                if QRScannerView.isAvailable {
                    Button {
                        problem = nil
                        code = ""
                        scanToken = UUID()
                        stage = .scanning
                    } label: {
                        Text("改扫码")
                            .font(.aevis(15))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .aevisGlass(cornerRadius: 14)
                }

                Button {
                    Task { await submitCode() }
                } label: {
                    Text("授权")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(code.count == 6
                                    ? AppSettings.shared.accentColor
                                    : Color.gray.opacity(0.45),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(code.count != 6)
            }
        }
        .padding(18)
        .onAppear { codeFocused = true }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("要用这台手机授权电脑版登录吗？")
                    .font(.aevis(16, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                // ⚠️ **别在这个字符串里用 `**` 想加粗** —— 拼接出来的 `Text` 走的是
                //    原文渲染，星号会原样显示在用户脸上（R17，项目里栽过）。
                Text("点了「授权」之后，那台电脑会立刻登上你 Aevis 里的这个账号，"
                     + "并且和你现在用的她绑在一起。"
                     + "\n\n如果不是你刚在电脑上点开的，就别授权。")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                row("服务器", ticket?.base ?? PairClient.currentBase)
                let shown = ticket?.code.isEmpty == false ? (ticket?.code ?? "") : code
                if !shown.isEmpty {
                    row("配对码", shown)
                }
                row("协议版本", "v\(ticket?.version ?? 1)")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aevisGlass(cornerRadius: 16)

            if let problem {
                Text(problem)
                    .font(.aevis(12.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button {
                    restart()
                } label: {
                    Text("不是这台")
                        .font(.aevis(15))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .aevisGlass(cornerRadius: 14)

                Button {
                    Task { await submit() }
                } label: {
                    Text("授权")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AppSettings.shared.accentColor,
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
    }

    private var busy: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("正在告诉电脑…")
                .font(.aevis(14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var done: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
            Text(gotAlready ? "这台电脑本来就连着" : "「\(gotName)」已经登上了")
                .font(.aevis(16, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Text("以后想解除，去「设置 → 账号与数据 → 配对电脑版」。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
            Button {
                dismiss()
            } label: {
                Text("好")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40)
                    .padding(.vertical, 11)
                    .background(AppSettings.shared.accentColor,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failed: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(problem ?? "没成。")
                .font(.aevis(14))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            HStack(spacing: 12) {
                Button {
                    restart()
                } label: {
                    Text("重来")
                        .font(.aevis(15))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .aevisGlass(cornerRadius: 14)
                }
                .buttonStyle(.plain)

                Button {
                    dismiss()
                } label: {
                    Text("算了")
                        .font(.aevis(15))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .aevisGlass(cornerRadius: 14)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.aevis(12.5).monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - 动作

    private func handleScanned(_ text: String) {
        guard stage == .scanning else { return }     // 认到一段就够，别被连报十几遍影响
        guard let parsed = PairClient.parse(text) else {
            // 扫到的不是配对码 —— **不能静默**，否则用户只会觉得"扫了没反应"
            problem = PairClient.Failure.notOurCode.errorDescription
            stage = .failed
            return
        }
        ticket = parsed
        problem = nil
        stage = .confirming
    }

    private func restart() {
        ticket = nil
        problem = nil
        code = ""
        scanToken = UUID()          // 换实例，否则新码认不出来
        stage = mode == .manual ? .manual : .scanning
    }

    private func submitCode() async {
        let digits = String(code.filter { $0.isNumber }.prefix(6))
        guard digits.count == 6 else {
            problem = "配对码是 6 位数字。"
            return
        }
        ticket = nil
        problem = nil
        stage = .working
        await perform(ticket: nil, code: digits, base: PairClient.currentBase)
    }

    private func submit() async {
        guard let ticket else { return }
        stage = .working
        await perform(ticket: ticket.ticket, code: nil, base: ticket.base)
    }

    private func perform(ticket ticketValue: String?, code codeValue: String?,
                         base: String) async {
        do {
            let claim = try await PairClient.claim(ticket: ticketValue, code: codeValue, base: base)
            PairClient.remember(session: claim.session, pcName: claim.pcName, pcOS: claim.pcOS)
            gotName = claim.pcName
            gotAlready = claim.already
            stage = .done
        } catch let failure as PairClient.Failure {
            problem = failure.errorDescription
            stage = .failed
        } catch {
            problem = error.localizedDescription
            stage = .failed
        }
    }
}
