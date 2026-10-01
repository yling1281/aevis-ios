import SwiftUI

/// 二探针界面。和第一颗一样**极简** —— 诊断工具，界面花哨一分、判断就少一分。
///
/// 唯一多出来的东西是「**先占音频会话**」那个开关：
/// 主 App 一起床就有人在动音频（QQ 保活 / 音乐），第一颗探针是干净启动。
///
/// **同一次安装里两种都试一遍**，比再出一个包快得多 ——
/// 两次结果不一样，就当场锁定"音频会话被占"这条原因。
struct CallProbe2View: View {
    @EnvironmentObject private var model: CallProbe2Model

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                statusCard
                audioToggle
                buttons
                logBox
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .navigationTitle("通话二探针")
            .navigationBarTitleDisplayMode(.inline)
        }
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
        case .ringing: return .green
        case .failed: return .red
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle: return "拨一通「假电话」，只看系统界面弹不弹（3 秒自动挂断）。拨完点「复制全部」发我。"
        case .starting: return "在等系统回话，最多等 6 秒…"
        case .ringing: return "✅ 系统界面弹出来了 —— 元凶就是「嵌了录屏扩展」那一条。"
        case .failed: return "这一轮不行。把开关切一下再拨第二次，两次对比着看。"
        }
    }

    // MARK: - 音频会话开关

    private var audioToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $model.occupyAudioFirst) {
                Text("拨号前先占住音频会话")
                    .font(.system(size: 14, weight: .medium))
            }
            // ⚠️ R17：单行 Text 字面量不解析 markdown，星号会原样显示出来，
            //    所以这里**不能**用 `**…**` 加粗，直接说就行。
            Text("主 App 一起床就有人在动音频（QQ 保活、放歌）。开着 = 像主 App；"
                 + "关掉 = 像第一颗探针。两种都试一遍，结果不一样就说明是这条。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 按钮

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                Task { await model.start() }
            } label: {
                Text("拨一通试试").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase == .starting)

            HStack(spacing: 10) {
                Button {
                    model.reset()
                } label: {
                    Text("重置").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    model.copyAll()
                } label: {
                    Label(model.justCopied ? "已复制" : "复制全部",
                          systemImage: model.justCopied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
