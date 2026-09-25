import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 全屏播放器 —— 仿网易云那个界面。
///
/// 四样东西撑起它的长相：
/// 1. **模糊放大的封面**当底子（歌是它的一部分，界面也是）
/// 2. 中间一张**会慢慢转的唱片**，旁边搭一根唱针
/// 3. **歌词**：当前那句大字，下一句小字
/// 4. **两个人的头像**并排 —— 一起听的时候，你在左边、TA 在右边
///
/// 用户的原话：「模仿网易云的播放界面」「默认一起听，就是两个人的头像用那个」。
///
/// 出厂就是**自动一起听**（`listenTogetherAutoStart`），但她不会自动念出来 ——
/// 歌在放，再叠一层人声就听不清了，想听哪句点小喇叭。
struct PlayerView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    private var persona: Persona { personaStore.persona }

    /// 唱片直径。跟屏幕宽度挂钩，但别大得离谱。
    private var discSize: CGFloat {
        #if canImport(UIKit)
        return min(UIScreen.main.bounds.width - 104, 288)
        #else
        return 260
        #endif
    }

    var body: some View {
        ZStack {
            backdrop
            content
        }
        .onAppear { autoStartTogether() }
        .preferredColorScheme(.dark)
    }

    // MARK: - 底子：模糊封面

    private var backdrop: some View {
        ZStack {
            Color.black

            AsyncImage(url: player.current?.coverURL) { phase in
                if case .success(let image) = phase {
                    Color.clear
                        .overlay(image.resizable().scaledToFill())
                        .blur(radius: 60)
                        .opacity(0.55)
                        // 兜一道尺寸：overlay 本身不裁剪，模糊过的图会往四周溢出去
                        .clipped()
                } else {
                    // 没封面时用主题色铺一层，仍然是那种「从封面里透出来的光」
                    LinearGradient(
                        colors: [settings.accentColor.opacity(0.55), Color.black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }

            // 压暗一层，保证白字压得住
            Color.black.opacity(0.30)
        }
        .ignoresSafeArea()
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 6)

            discArea

            Spacer(minLength: 8)

            lyricArea

            Spacer(minLength: 8)

            progressArea

            controlArea

            bottomArea
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 6) {
            // 一起听那个小标居中放在歌名上方。用 ZStack 叠，不要在一行里塞两个 Spacer
            // —— 两个的话剩余空白会被平分，两边的控件就不贴边了。
            ZStack {
                if together.active {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2.fill")
                            .font(.aevis(11, weight: .medium))
                        Text("一起听")
                            .font(.aevis(11.5, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.14)))
                }

                HStack(spacing: 0) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.aevis(17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    // 和左边那个按钮等宽，歌名/小标才真的居中
                    Color.clear.frame(width: 40, height: 40)
                }
            }

            if let track = player.current {
                Text(track.title)
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.aevis(12.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text("还没在放歌")
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - 唱片
    //
    // 会转的那张。用 `Color.clear` 撑尺寸、图放 overlay ——
    // 直接把 `scaledToFill` 摆进布局里会把整棵布局撑大（这条踩过）。
    //
    // ⚠️ 旋转**挂在唱片本体上，不挂在唱针上** —— 挂外层连唱针一起转，
    // 看着就像针在唱片上划圈。

    private var discArea: some View {
        ZStack {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.07))

                Circle()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .padding(12)

                coverLayer
                    .padding(discSize * 0.19)
            }
            .frame(width: discSize, height: discSize)
            // 角度直接**由播放进度推出来**，不用计时器：
            // 每秒 6°（60 秒一圈），而 progress 每 0.5 秒更新一次 → 每步 3°，
            // 用 0.5 秒的线性动画接起来就是连续转。**暂停时 progress 不动，它自然就停了。**
            .rotationEffect(.degrees(player.progress * 6))
            .animation(
                player.isPlaying ? .linear(duration: 0.5) : .easeOut(duration: 0.3),
                value: player.progress
            )
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)

            // 唱针：在转就搭上去，暂停就抬起来
            Capsule()
                .fill(.white.opacity(0.72))
                .frame(width: 6, height: discSize * 0.28)
                .rotationEffect(.degrees(player.isPlaying ? 0 : -26), anchor: .top)
                .offset(x: discSize * 0.28, y: -discSize * 0.40)
        }
        .frame(width: discSize, height: discSize)
        // 给唱针往左上冒出来的那一段留位置
        .padding(.top, 30)
    }

    private var coverLayer: some View {
        Color.clear
            .overlay(
                AsyncImage(url: player.current?.coverURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        placeholderDisc
                    }
                }
            )
            .clipShape(Circle())
    }

    /// 没封面（或者还在下载）时的那张假唱片。
    private var placeholderDisc: some View {
        ZStack {
            LinearGradient(
                colors: [
                    settings.accentColor.opacity(0.95),
                    settings.accentColor.opacity(0.40)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.aevis(46, weight: .light))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    // MARK: - 歌词 + 她的话

    private var lyricArea: some View {
        VStack(spacing: 11) {
            if let line = player.currentLyricLine {
                Text(line)
                    .font(.aevis(21, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let next = player.nextLyricLine {
                    Text(next)
                        .font(.aevis(14))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if player.current != nil {
                Text(player.lyric.isEmpty ? "这首歌没有歌词" : "前奏…")
                    .font(.aevis(17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("在「音乐」里搜一首，或者直接跟 \(persona.pronoun) 说「放首歌」")
                    .font(.aevis(14))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 她刚说的那句。**不自动念** —— 想听点小喇叭。
            if let latest = together.herLines.first {
                HStack(alignment: .top, spacing: 8) {
                    AevisAvatar(source: .ai, size: 22, seed: persona.avatarSeed)

                    Text(latest)
                        .font(.aevis(13.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        together.speak(latest)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.aevis(12.5))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.white.opacity(0.10))
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 116, alignment: .center)
    }

    // MARK: - 两个人的头像

    /// 一起听开着才出现 —— 你在左、TA 在右。
    private var togetherRow: some View {
        HStack(spacing: 16) {
            avatarSlot(source: .me, title: "我")
            Image(systemName: "heart.fill")
                .font(.aevis(13))
                .foregroundStyle(.white.opacity(0.7))
            avatarSlot(source: .ai, title: persona.name.isEmpty ? "TA" : persona.name)
        }
    }

    private func avatarSlot(source: AevisAvatar.Source, title: String) -> some View {
        VStack(spacing: 5) {
            AevisAvatar(source: source, size: 44, seed: persona.avatarSeed)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5))
            Text(title)
                .font(.aevis(10.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }

    // MARK: - 进度

    private var progressArea: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: {
                        // 值和别处一样要夹住：AVPlayer 会给 NaN，NaN 进 SwiftUI 就是崩。
                        guard player.duration > 0, player.progress.isFinite else { return 0 }
                        return min(max(player.progress / player.duration, 0), 1)
                    },
                    set: { player.seek(to: min(max($0, 0), 1)) }
                ),
                in: 0...1
            )
            .tint(.white.opacity(0.85))

            HStack(spacing: 8) {
                Text(Self.time(player.progress))
                Spacer(minLength: 8)
                Text(Self.time(player.duration))
            }
            .font(.aevisMono(10.5))
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    // MARK: - 控制

    private var controlArea: some View {
        HStack(spacing: 30) {
            controlButton("backward.fill", size: 22) {
                Task { await player.previous() }
            }

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.aevis(26, weight: .medium))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(.white.opacity(0.94)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            controlButton("forward.fill", size: 22) {
                Task { await player.next() }
            }
        }
        .padding(.top, 12)
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.aevis(size, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部：一起听

    private var bottomArea: some View {
        VStack(spacing: 11) {
            if together.active {
                togetherRow

                HStack(spacing: 12) {
                    Button {
                        Task { await together.pokeHer() }
                    } label: {
                        Text(together.thinking ? "她在想…" : "让她说一句")
                            .font(.aevis(13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .disabled(together.thinking)

                    Button {
                        together.stop()
                    } label: {
                        Text("结束一起听")
                            .font(.aevis(13))
                            .foregroundStyle(.white.opacity(0.65))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Toggle(isOn: $settings.listenTogetherAutoStart) {
                    Text("放歌就一起听")
                        .font(.aevis(13))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .tint(settings.accentColor)

                Button {
                    startTogether()
                } label: {
                    Text(settings.isConfigured ? "现在就开始一起听" : "要填了 API Key 她才会说话")
                        .font(.aevis(13, weight: .medium))
                        .foregroundStyle(.white.opacity(settings.isConfigured ? 0.9 : 0.45))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(!settings.isConfigured)
            }

            if let status = together.statusLine {
                Text(status)
                    .font(.aevis(11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - 一起听

    /// 打开播放器就顺手开始一起听 —— 用户要的「默认一起听」。
    ///
    /// 三个前提缺一不可，否则她会一直报错或者干脆不说话：
    /// 开关开着、模型配好了、而且现在确实有歌在放。
    private func autoStartTogether() {
        guard settings.listenTogetherAutoStart else { return }
        guard !together.active, player.current != nil else { return }
        startTogether()
    }

    private func startTogether() {
        guard !together.active else { return }
        guard settings.isConfigured else { return }
        let mode = ListenTogetherMode(rawValue: settings.listenTogetherMode) ?? .sync
        guard mode.isImplemented else { return }

        together.start(
            mode: mode,
            persona: persona,
            config: settings.llm,
            memory: settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        )
    }

    // MARK: - 零件

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
