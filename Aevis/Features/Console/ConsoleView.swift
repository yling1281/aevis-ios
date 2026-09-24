import SwiftUI

/// 命令台。
///
/// 不是模拟器截图里的装饰 —— 它真的能执行命令（文件、文本、网络），
/// 只是所有文件操作都被关在 App 自己的工作目录里。
struct ConsoleView: View {
    @ObservedObject private var fonts = FontStore.shared

    @State private var lines: [ConsoleLine] = []
    @State private var input = ""
    @State private var running = false
    @State private var history: [String] = []
    @State private var historyIndex = -1
    @FocusState private var focused: Bool

    private let provider = Shell.provider

    private struct ConsoleLine: Identifiable {
        let id = UUID()
        var text: String
        var kind: Kind

        enum Kind {
            case command
            case output
            case failure
            case note
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            banner
            output
            quickCommands
            inputBar
        }
        .navigationTitle("命令台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") {
                    lines.removeAll()
                    append(Self.welcome, kind: .note)
                }
            }
        }
        .onAppear {
            if lines.isEmpty {
                append(Self.welcome, kind: .note)
            }
        }
    }

    // MARK: - 顶部说明

    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(provider.displayName)
                    .font(.aevis(14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(provider.isAvailable ? "可用" : "未接入")
                    .font(.aevis(11))
                    .foregroundStyle(provider.isAvailable ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            (provider.isAvailable ? Color.green : Color.orange).opacity(0.14)
                        )
                    )
                Spacer(minLength: 0)
            }
            Text(provider.availability)
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Rectangle().fill(.bar))
    }

    // MARK: - 输出

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.aevisMono(12.5))
                            .foregroundStyle(color(for: line.kind))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在执行…")
                                .font(.aevisMono(12.5))
                                .foregroundStyle(.secondary)
                        }
                        .id("running")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.black.opacity(0.03))
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: running) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onTapGesture { focused = false }
        }
    }

    private func color(for kind: ConsoleLine.Kind) -> Color {
        switch kind {
        case .command: return .primary
        case .output: return .primary.opacity(0.82)
        case .failure: return .red
        case .note: return .secondary
        }
    }

    // MARK: - 快捷命令

    private var quickCommands: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["help", "pwd", "ls", "date", "env"], id: \.self) { command in
                    Button {
                        input = command
                        execute()
                    } label: {
                        Text(command)
                            .font(.aevisMono(12.5))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .aevisGlass(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Rectangle().fill(.bar))
    }

    // MARK: - 输入

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.aevisMono(14, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("输一条命令，回车执行", text: $input)
                .font(.aevisMono(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .disabled(running)
                .submitLabel(.send)
                .onSubmit { execute() }

            Button(action: execute) {
                Image(systemName: running ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            running ? Color.gray.opacity(0.5)
                            : (input.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                        )
                    )
                    .contentShape(Circle())
            }
            .disabled(input.isEmpty && !running)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Rectangle().fill(.bar))
    }

    // MARK: - 执行

    private func execute() {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running else { return }

        input = ""
        history.append(command)
        historyIndex = history.count
        append("\(provider.workingDirectory) $ \(command)", kind: .command)

        running = true
        Task { @MainActor in
            let result = await Shell.run(command)
            running = false

            if result.output == "__CLEAR__" {
                lines.removeAll()
                return
            }
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                append(text, kind: result.exitCode == 0 ? .output : .failure)
            }
        }
    }

    private func append(_ text: String, kind: ConsoleLine.Kind) {
        lines.append(ConsoleLine(text: text, kind: kind))
    }

    private static let welcome = """
    欢迎。这里的命令会真的执行，不是演示。

    所有文件都在 App 自己的工作目录里，`..` 也出不去 ——
    这样她帮你整理文件时，不可能误删手机上的东西。

    想接真 Alpine Linux（能 apk 装包、跑 python/node）的话，
    需要把它的 rootfs 编进 App，那是后面的事。输 help 看现在能做什么。
    """
}
