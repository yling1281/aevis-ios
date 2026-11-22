import SwiftUI

/// 聊天（2026-11-17 骨架；2026-11-22 升级为流式 SSE）。
///
/// 本地历史能看、能发、括号变浅、头像/字号跟设置；回复走 SSE 逐字显示，
/// 增量到达即刷新气泡并滚动贴底；网络/格式异常有兜底与「重发」。
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
    /// 流式时 msgs.count 不变、content 变，靠这个 tick 触发滚动贴底。
    @State private var scrollTick = 0

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
                .onChange(of: scrollTick) { _ in
                    if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if !error.isEmpty {
                HStack(spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("重发") { Task { await resend() } }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .disabled(sending)
                }
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

    /// 输入框发送。
    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session.token != nil else { return }
        input = ""
        await performSend(text: text)
    }

    /// 失败后重发：删掉最后一条 user 及其后的回复，把那条 user 的原文重新送一遍。
    private func resend() async {
        guard let lastUser = msgs.last(where: { $0.role == "user" }) else { return }
        let text = lastUser.content
        if let idx = msgs.lastIndex(where: { $0.role == "user" }) {
            msgs = Array(msgs.prefix(upTo: idx))
        }
        LocalStore.save(pid: persona.id, msgs: msgs)
        await performSend(text: text)
    }

    /// 发送一段文本：落盘用户消息 → SSE 逐字收增量 → 落盘完整回复。
    private func performSend(text: String) async {
        guard let token = session.token else { return }
        var mine = Msg(role: "user", content: text)
        mine.id = UUID()
        msgs.append(mine)
        LocalStore.save(pid: persona.id, msgs: msgs)

        #if DEBUG
        if demo {
            // 截图模式：假的延时回一句，保持非流式（CI 截图靠它）
            sending = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            msgs.append(Msg(role: "assistant", content: "（她笑了笑）我在听。"))
            LocalStore.save(pid: persona.id, msgs: msgs)
            sending = false
            return
        }
        #endif

        // 先插一条空 assistant，后续每个 delta 按 id 增量拼到它上面（不是替换）
        let assistantID = UUID()
        var placeholder = Msg(role: "assistant", content: "")
        placeholder.id = assistantID
        msgs.append(placeholder)

        sending = true
        error = ""
        do {
            // 只带最近 20 条；dropLast 去掉刚插入的空 assistant，别把空内容发给模型
            let payload = msgs.dropLast().suffix(20).map { ["role": $0.role, "content": $0.content] }
            let full = try await APIClient.sendChatStream(
                token: token, model: "deepseek-flash", messages: payload,
                onDelta: { delta in
                    // onDelta 在 URLSession 后台线程回调，切回主线程改 @State 并触发滚动
                    DispatchQueue.main.async {
                        guard let i = msgs.firstIndex(where: { $0.id == assistantID }) else { return }
                        msgs[i].content += delta
                        scrollTick += 1
                    }
                }
            )
            // 收尾：用完整文本校准（防止增量回调排队丢帧），落盘 + 触发云备份
            DispatchQueue.main.async {
                if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
                    msgs[i].content = full
                    scrollTick += 1
                }
                LocalStore.save(pid: persona.id, msgs: msgs)
                CloudBackup.shared.pushIfNeeded(token: token)
            }
        } catch {
            DispatchQueue.main.async {
                self.error = error.localizedDescription
                if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
                    if msgs[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        msgs.remove(at: i)          // 一个字都没出：撤掉空气泡，可点「重发」
                    } else {
                        msgs[i].content += "\n（回复中断，可点「重发」）"
                        LocalStore.save(pid: persona.id, msgs: msgs)
                    }
                }
            }
        }
        sending = false
    }
}
