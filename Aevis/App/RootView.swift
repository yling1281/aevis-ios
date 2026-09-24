import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            AevisBackground()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)

                    AevisOrb()

                    Text("Aevis")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .padding(.top, 30)

                    Text("她还没有名字，也还没有性格。")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)

                    Text("这一步只证明一件事 —— 这条路走得通。")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)

                    DiagnosticsCard()
                        .padding(.top, 36)

                    MilestoneNote()
                        .padding(.top, 16)

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 22)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct DiagnosticsCard: View {
    private let rows: [(String, String)] = [
        ("系统版本", Diagnostics.osVersion),
        ("设备代号", Diagnostics.machine),
        ("App 版本", Diagnostics.appVersion),
        ("构建提交", Diagnostics.commit),
        ("液态玻璃", Diagnostics.supportsLiquidGlass ? "可用" : "不可用"),
        ("签名状态", Diagnostics.isSigned ? "已签名" : "未签名"),
        ("内置 Linux", Diagnostics.hasLinuxSandbox ? "已就绪" : "未接入")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("环境自检")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(row.0)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.1)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 11)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.bottom, 8)
        .aevisGlass(cornerRadius: 22)
    }
}

private struct MilestoneNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("M0 · 骨架验证版")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Text("这一版只做四件事：证明代码能在云端编译、能签名、能装进你的手机、能启动并读到系统信息。从 M1 开始，她会开始说话。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .aevisGlass(cornerRadius: 22)
    }
}

#Preview {
    RootView()
}
