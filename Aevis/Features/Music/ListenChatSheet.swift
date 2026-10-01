import SwiftUI

/// 一起听的时候，跟他/她**互相打字**的那个界面。
///
/// 用户原话（2026-09-30）：「我们不能两个人互相打字聊天，要加一个输入框，
/// 能互相打字聊天的」。
///
/// ## 为什么是弹一层，而不是把输入框塞进播放器里
/// 播放器那一屏是**满的**：模糊封面 + 唱片 + 唱针 + 两句歌词 + 进度 + 三个按钮，
/// 底下再压一条输入框，键盘一弹（300 点）整棵布局会被挤到变形 ——
/// 唱片直接被压扁，而那是这一屏最好看的东西。
/// 弹起来的这一层自带输入框、自带滚动，键盘归键盘、唱片归唱片。
///
/// ## 和「聊天」页的关系
/// **不是**另一个聊天页：这里打的字会同步进正式聊天记录
/// （见 `ListenTogetherService.send`），所以关掉播放器之后这段对话还在，
/// 她回到聊天页也记得。这一层只是"一边听歌一边打字的那个窗口"。
struct ListenChatSheet: View {
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var persona: Persona { personaStore.persona }
    private var name: String { persona.name.isEmpty ? "TA" : persona.name }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                transcript
                inputBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // 打开就把键盘叫上来 —— 用户点进来就是为了打字，
            // 还要再点一下输入框才能打，那等于多一道没用的门。
            inputFocused = true
        }
    }

    // MARK: - 底子

    private var backdrop: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [settings.accentColor.opacity(0.30), Color.black],
                startPoint: .topLeading,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("跟 \(name) 打字聊")
                    .font(.aevis(16, weight: .semibold))
                    .foregroundStyle(.white)

                if let track = player.current {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.aevis(9.5))
                        Text("一边听 \(track.title)")
                            .font(.aevis(11.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.aevis(15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - 中间的对话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if together.chatLines.isEmpty {
                        emptyHint
                    }
                    ForEach(together.chatLines) { line in
                        bubble(for: line)
                    }
                    // 滚动用的锚点 —— 新消息来了就滚到它身上
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            }
            // 新的一行、或者她正在吐的那半句变长了，都往下贴
            .onChange(of: together.chatLines.count) { _, _ in
                scrollDown(proxy)
            }
            .onChange(of: together.chatLines.last?.text) { _, _ in
                scrollDown(proxy)
            }
            .onChange(of: together.replying) { _, _ in
                scrollDown(proxy)
            }
        }
    }

    private static let bottomID = "listen-chat-bottom"

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    /// 一条字都还没打的时候说清楚这里是干嘛的。
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.aevis(26, weight: .light))
                .foregroundStyle(.white.opacity(0.4))
            Text("在这里打字，\(name) 会接着你的话回。\n歌一直在放，不会断。")
                .font(.aevis(13))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - 一条气泡

    @ViewBuilder
    private func bubble(for line: ListenTogetherService.Line) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if line.mine {
                Spacer(minLength: 46)
                bubbleBody(line)
                AevisAvatar(source: .me, size: 26, seed: persona.avatarSeed)
            } else {
                AevisAvatar(source: .ai, size: 26, seed: persona.avatarSeed)
                bubbleBody(line)
                Spacer(minLength: 46)
            }
        }
    }

    private func bubbleBody(_ line: ListenTogetherService.Line) -> some View {
        // 空的那条 = 她还在想。放三个点，不要空着一块白。
        let text = line.text.isEmpty ? "…" : line.text

        return Text(text)
            .font(.aevis(15.5))
            .foregroundStyle(line.mine ? .white : .white.opacity(0.94))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(
                        line.mine
                            ? settings.accentColor.opacity(0.85)
                            : .white.opacity(0.13)
                    )
            )
            .contentShape(Rectangle())
            // 点她的话就念出来 —— 跟播放器里那个小喇叭一个规矩
            .onTapGesture {
                guard !line.mine, !line.text.isEmpty else { return }
                together.speak(line.text)
            }
    }

    // MARK: - 底部输入

    private var inputBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                TextField("跟 \(name) 说点什么…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .font(.aevis(15.5))
                    .foregroundStyle(.white)
                    .tint(settings.accentColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .submitLabel(.send)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.aevis(16, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(settings.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
            }

            HStack(spacing: 6) {
                if together.replying {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.6))
                    Text("\(name) 在想…")
                        .font(.aevis(11))
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("打过的字会留在聊天记录里")
                        .font(.aevis(11))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !together.replying
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !together.replying else { return }
        draft = ""
        BlackBox.tap("一起听 · 打字聊")
        Task { await together.send(text) }
    }
}
