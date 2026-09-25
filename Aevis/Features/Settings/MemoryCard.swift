import SwiftUI

/// 「长期记忆」设置卡片。
///
/// 用户原话：「长期记忆，然后记忆库备份。」
/// 所以这里不只是个开关 —— 点进去是一个能自己管的记忆库。
struct MemoryCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var memory = MemoryStore.shared

    /// 截图自检用：带参数启动时直接把记忆库推出来。
    @State private var openList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("长期记忆")

            toggleRow(
                "自动记住",
                subtitle: "聊够一段就让\(Pronoun.current)把值得记住的挑出来存下",
                isOn: $settings.memoryEnabled
            )

            if settings.memoryEnabled {
                rule

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("每攒够多少条聊一次")
                            .font(.aevis(14))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(settings.memoryExtractEvery) 条")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.memoryExtractEvery) },
                            set: { settings.memoryExtractEvery = Int($0.rounded()) }
                        ),
                        in: 6...60,
                        step: 2
                    )
                    Text("调小\(Pronoun.current)记性好但费 token，调大省钱但记性慢。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            rule

            toggleRow(
                "每次对话都带上记忆",
                subtitle: "关掉之后记忆还在，只是这次聊天不拿出来用",
                isOn: $settings.memoryInjectEnabled
            )

            rule

            NavigationLink {
                MemoryListView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "tray.full")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(AppSettings.shared.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("记忆库")
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(memory.items.isEmpty
                             ? "还什么都没记住"
                             : "已经记住 \(memory.items.count) 条")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let status = memory.statusLine {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
                Text(status)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
        .aevisGlass(cornerRadius: 20)
        .navigationDestination(isPresented: $openList) {
            MemoryListView()
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenMemoryList") {
                openList = true
            }
            #endif
        }
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

    private func toggleRow(_ text: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
