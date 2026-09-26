import SwiftUI
import UIKit

/// 探针界面。刻意做得**极简**：
/// 只有"现在什么状态"、"按钮"、"日志"三样 —— 这是个诊断工具，
/// 界面花哨一分，判断就少一分可信。
struct ProbeView: View {
    @EnvironmentObject private var model: ProbeModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                statusCard
                buttons
                logBox
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .navigationTitle("VPN 探针")
            .navigationBarTitleDisplayMode(.inline)
        }
        // 体检报告放在这里打，而不是 ProbeModel 的 init 里 ——
        // 因为那个 init 现在得是空的（主 actor 那套限制，见 ProbeModel 注释）。
        .task { await model.report() }
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(model.phase.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private var tint: Color {
        switch model.phase {
        case .idle: return .secondary
        case .starting: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle: return "点下面的按钮开始。这个测试不接管任何流量，不影响上网。"
        case .starting: return "在等系统回话，最多等 20 秒…"
        case .running: return "这套签名能跑网络扩展 —— 拦抖音那条路是通的。"
        case .failed: return "下面日志里那几行就是原因，整份复制给我看。"
        }
    }

    // MARK: - 按钮

    private var buttons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.start() }
                } label: {
                    Text("启动隧道").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.phase == .starting)

                Button {
                    model.stop()
                } label: {
                    Text("停止").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.phase == .idle)
            }

            HStack(spacing: 10) {
                Button {
                    model.copyAll()
                } label: {
                    Label(model.justCopied ? "已复制" : "复制全部",
                          systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await model.forget() }
                } label: {
                    Text("删掉配置").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .font(.system(size: 14))
        }
    }

    // MARK: - 日志

    private var logBox: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.lines.joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("bottom")
            }
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: model.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}
