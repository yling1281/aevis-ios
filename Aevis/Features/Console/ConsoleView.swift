import SwiftUI

/// 命令台。
///
/// 内置 Linux（iSH / AlpineRuntime / ShellProvider）已于 2026-11-02 整体移除，
/// 执行命令的能力随之下线。这里保留入口不删，避免设置页少一块，
/// 打开后给一句明确说明，而不是白屏或报错。
///
/// 需要执行命令时走服务器通道（backend 有对应接口），不要再往 App 里塞运行时。
struct ConsoleView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaperSpace.md) {
                PaperCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("命令台已下线")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Paper.ink)

                        Text("内置 Linux 在 2026-11-02 被整体移除（占 200MB、启动慢、维护成本高）。\n执行命令的能力一并下线，需要跑命令请走服务器通道。")
                            .font(.system(size: 12))
                            .lineSpacing(5)
                            .foregroundColor(Paper.inkSub)
                    }
                    .padding(16)
                }
            }
            .padding(.horizontal, PaperSpace.lg)
            .padding(.top, PaperSpace.md)
        }
        .background(Paper.bg)
        .navigationTitle("命令台")
        .navigationBarTitleDisplayMode(.inline)
    }
}
