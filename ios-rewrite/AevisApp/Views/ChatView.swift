import SwiftUI

/// 聊天（2026-11-17，134 骨架）。
///
/// 这一版只保证：本地历史能看、能发、括号变浅、头像/字号跟设置。
/// 流式（SSE）留到下一版 —— 现在用非流式接口拿到整段再一次性插入，
/// 先把编译链和接口跑通，别在骨架上做半套流式。
struct ChatView: View {
    @EnvironmentObject private var session: Session
    let persona: Persona
    #if DEBUG
    /// 137：CI 截图用的样例模式（不读写本地、不发请求）。Release 编不进去。
    var demo: Bool = false
    #endif

    @State private var msgs: [Msg] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error = ""

    @AppStorage("msgSize") private var msgSize = 1          // 0 小 / 1 标准 / 2 大
    @AppStorage("annotDim") private var annotDim = true
    @AppStorage("avatarMode") private var avatarMode = 0    // 0 双方 / 1 只角色 / 2 都不显示

    /// 三档字号（与安卓 msgSize 一致；行高 = ×1.45）
    private var fontSize: CGFloat { AE.chatFont(msgSize) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(msgs) { m in
                            row(m).id(m.id)
                        }
                        if sending {
                            HStack {
                                Text("正在输入…").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: msgs.count) { _ in
                    if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }

            HStack(spacing: 8) {
                TextField("说点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.regularMaterial)
        }
        .navigationTitle(persona.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG
            if demo {
                msgs = [
                    Msg(role: "user", content: "在吗"),
                    Msg(role: "assistant", content: "（她抬眼看你）在的，刚泡了杯茶。今天想聊点什么？"),
                    Msg(role: "user", content: "随便聊聊，今天有点累"),
                    Msg(role: "assistant", content: "那就别硬撑了。（把椅子往你这边挪了挪）先说说，是身体累还是心里累？")
                ]
            } else {
                msgs = LocalStore.load(pid: persona.id)
            }
            #else
            msgs = LocalStore.load(pid: persona.id)
            #endif
        }
    }

    @ViewBuilder
    private func row(_ m: Msg) -> some View {
        let mine = m.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if !mine && avatarMode != 2 {
                avatar(URL(string: abs(persona.avatar)), name: persona.name)
            }
            if mine { Spacer(minLength: 40) }

            Text(annotated(m.content))
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.45)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(mine ? AE.accent.opacity(0.20) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AE.bubbleRadius, style: .continuous))

            if !mine { Spacer(minLength: 40) }
            if mine && avatarMode == 0 {
                avatar(nil, name: "我")
            }
        }
        .padding(.horizontal, 12)
    }

    /// 括号内容变浅：`（…）` / `(…)` 用 60% 前景色（跟安卓同一套）。
    private func annotated(_ text: String) -> AttributedString {
        var out = AttributedString()
        var depth = 0
        for ch in text {
            if ch == "（" || ch == "(" { depth += 1 }
            var piece = AttributedString(String(ch))
            if depth > 0 && annotDim {
                piece.foregroundColor = .secondary.opacity(0.6)
            }
            if ch == "）" || ch == ")" { depth = max(0, depth - 1) }
            out.append(piece)
        }
        return out
    }

    @ViewBuilder
    private func avatar(_ url: URL?, name: String) -> some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Text(String(name.prefix(1)))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Circle())
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    private func abs(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("http") { return path }
        if path.hasPrefix("/") { return APIClient.base + path }
        return path
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let token = session.token else { return }
        input = ""
        var mine = Msg(role: "user", content: text)
        mine.id = UUID()
        msgs.append(mine)
        LocalStore.save(pid: persona.id, msgs: msgs)

        #if DEBUG
        if demo {
            // 截图模式：假装回一句，让气泡样式能被拍到
            sending = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            msgs.append(Msg(role: "assistant", content: "（她笑了笑）我在听。"))
            sending = false
            return
        }
        #endif

        sending = true; error = ""
        do {
            // 只带最近 20 条，骨架阶段够用；真正的上下文窗口策略跟安卓一致再补
            let payload = msgs.suffix(20).map { ["role": $0.role, "content": $0.content] }
            let reply = try await APIClient.sendChat(
                token: token, model: "deepseek-flash", messages: payload
            )
            msgs.append(Msg(role: "assistant", content: reply))
            LocalStore.save(pid: persona.id, msgs: msgs)
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
