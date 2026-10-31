import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 全屏播放器 —— 仿网易云那个界面。
///
/// ## 它同时就是「一起听」的界面（2026-10-01 用户拍板）
///
/// 用户原话：「把『一起听』砍掉，做成官网那样的界面」「现在的『一起听』不好用」。
///
/// 拍板后的结论：**这个界面本来就是那个"官网那样的界面"** ——
/// 而原来「发现 → 一起听」打开的是 `TogetherView`，三张设置卡片，
/// 跟"一起听"这件事本身毫无关系。所以这次：
/// - `TogetherView` **整个删掉**，模式选择当时搬进了这里
///   （2026-10-02 连**模式选择本身**也删了 —— 见 `bottomArea` 里那段说明）
/// - 所有「一起听」入口（发现页 / 聊天加号 / 通话申请）**都改成打开这个界面**
/// - 找歌也从「音乐」页搬进来（右上角放大镜，见 `MusicSearchSheet`）——
///   以前想换歌得退出去翻页，一起听会断，这是"不好用"的一半原因
///
/// 四样东西撑起它的长相：
/// 1. **模糊放大的封面**当底子（歌是它的一部分，界面也是）
/// 2. 中间一张**会慢慢转的唱片**，旁边搭一根唱针
/// 3. **歌词**：当前那句大字，下一句小字
/// 4. **两个人的头像**并排 —— 一起听的时候，你在左边、ta 在右边
///
/// 用户的原话：「模仿网易云的播放界面」「默认一起听，就是两个人的头像用那个」。
///
/// 出厂就是**自动一起听**（`listenTogetherAutoStart`），但ta不会自动念出来 ——
/// 歌在放，再叠一层人声就听不清了，想听哪句点小喇叭。
struct PlayerView: View {
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    /// 找歌面板。没歌在放时进来会自动弹 —— 不然这个界面是一片空白。
    @State private var showSearch = false

    /// 「打字聊」那一层（用户 2026-09-30 要的输入框）。
    ///
    /// ⚠️ 它和 `showSearch` 是**挂在两个不同的视图上**的（一个挂在 `content`、
    ///    一个挂在最外层的 `ZStack`）。同一个视图上叠两个 `.sheet` 时，
    ///    SwiftUI 只认最后一个，另一个会"点了没反应" —— 这是老坑，
    ///    靠着分开放才不用去写一层枚举来管。
    @State private var showChat = false

    /// 当前皮肤。改动前这里整套配色是硬编码的深色，现在全部从它取。
    ///
    /// ⚠️ 用 `@State` 举着当前值（不每次从 `UserDefaults` 重读）——
    ///    切换时先改这里、再写盘，视图立刻重绘。默认那套（深夜）的强调色是
    ///    **实时**向 `AppSettings` 取的（见 `PlayerTheme.accent`），
    ///    所以这里就算是快照，用户改全局主题色时它照样跟着变。
    @State private var theme: PlayerTheme = PlayerTheme.current

    /// 换皮肤那个小面板开没开。
    @State private var showThemePicker = false

    /// 红心状态（当前这首歌是不是已经在「我喜欢的音乐」里）。
    @State private var likedNow = false

    /// 中间那块现在是**唱片**还是**歌词**（用户 2026-10-31：
    /// 「中间要不就是大圆圈在那里转圈，要不就是点一下是歌词」）。
    ///
    /// 只看这一块，不要把两样同时摆出来 —— 上下各占一半的结果是
    /// 唱片不够大、歌词只露三行，两头都不好看。
    @State private var showLyrics = false

    /// 评论面板（真实网易云评论）。
    @State private var showComments = false

    /// 正在拉的 MV。有值就掀开播放器；`nil` 什么都不做。
    @State private var mv: MVRequest?

    /// MV 播放要用的那两个值。
    struct MVRequest: Identifiable {
        let id = UUID()
        var url: URL
        var title: String
    }

    /// 底部功能行的提示语（红心成功、还没接上的功能都靠它说话）。
    ///
    /// ⚠️ 项目里**没有全局 toast**，所以在播放器自己挂一条。
    ///   3 秒后自己消失，不挡操作。
    @State private var note: String? = nil
    @State private var noteTask: Task<Void, Never>? = nil

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
            // 打字聊那一层挂在这里；找歌那一层挂在下面（见 `showChat` 的说明）。
            content
                .sheet(isPresented: $showChat) {
                    ListenChatSheet()
                }
                // 评论 / MV 各自挂一层 —— 同一个视图上叠多个 `.sheet` 时
                // SwiftUI 只认最后一个（见 `showChat` 的说明），所以必须分开挂。
                .sheet(isPresented: $showComments) {
                    MusicCommentsSheet(songID: player.current?.id ?? "",
                                       title: player.current?.title ?? "")
                }
                .sheet(item: $mv) { item in
                    MVPlayerSheet(url: item.url, title: item.title)
                }
        }
        .onAppear {
            // 空着进来就先让他找首歌 —— 否则界面上一句「还没在放歌」，
            // 加上「一起听」的按钮全是灰的，等于白打开一次。
            if player.current == nil {
                showSearch = true
            } else {
                autoStartTogether()
            }
            #if DEBUG
            // 截图自检用：直接把「打字聊」那一层掀开
            //（模拟器里没 API Key，正常路径永远打不开它）。
            if ProcessInfo.processInfo.arguments.contains("-aevisOpenListenChat") {
                showChat = true
            }
            #endif
        }
        // ⚠️ `onDismiss` 里那个 `autoStartTogether()` 不能省：
        // 空着进来时 `onAppear` 只把找歌面板打开了、没启动一起听；
        // 等他挑完歌把面板收起来，才轮到一起听开始。
        .sheet(isPresented: $showSearch, onDismiss: { autoStartTogether() }) {
            MusicSearchSheet()
        }
        // 换皮肤。用系统那个 action sheet 就够了 —— 列一串预设、点一个立即生效，
        // 不用自己搭 sheet，屏幕上也不多留一块常驻控件。
        .confirmationDialog(
            "播放器皮肤",
            isPresented: $showThemePicker,
            titleVisibility: .visible
        ) {
            ForEach(PlayerTheme.all) { item in
                Button(item.id == theme.id ? "✓ \(item.name)" : item.name) {
                    applyTheme(item)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(theme.tagline)
        }
        // 深色皮肤走 `.dark`、浅色皮肤（极简白 / 樱花）走 `.light`。
        .preferredColorScheme(theme.scheme)
    }

    // MARK: - 底子：模糊封面

    private var backdrop: some View {
        ZStack {
            theme.background

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
                        colors: [theme.accent.opacity(0.55), theme.background],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }

            // 压一层，保证字压得住。深色底上就是压暗、浅色底上就是提亮 ——
            // 用底色本身来压，两种方向都自然。
            theme.background.opacity(0.30)
        }
        .ignoresSafeArea()
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 6)

            // 中间这一块：唱片 ⇄ 歌词，点一下换。两样**不同时出现**。
            stage

            Spacer(minLength: 8)

            progressArea

            controlArea

            bottomArea

            // 功能行的提示语（红心成功 / 还没接上的功能）。
            // 放在最底下、跟着内容走 —— 不做成浮层，免得挡住唱片。
            if let note {
                Text(note)
                    .font(.aevis(11.5))
                    .foregroundStyle(theme.onBackground.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.2), value: note)
    }

    /// 中间那块：**会转的唱片** 或 **整屏歌词**，点一下切换。
    ///
    /// 高度锁在唱片直径上 —— 不锁的话切到歌词时整页会跳一下，
    /// 因为 ScrollView 的高度和 Circle 不一样。
    private var stage: some View {
        ZStack {
            if showLyrics {
                lyricArea
                    .transition(.opacity)
            } else {
                discArea
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: discSize + 30)
        .contentShape(Rectangle())
        .onTapGesture {
            guard player.current != nil else { return }
            BlackBox.tap(showLyrics ? "播放器 · 切回唱片" : "播放器 · 切到歌词")
            withAnimation(.easeInOut(duration: 0.26)) { showLyrics.toggle() }
        }
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
                        Text("网易云")
                            .font(.aevis(11.5, weight: .medium))
                    }
                    .foregroundStyle(theme.onBackground.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.onBackground.opacity(0.14)))
                }

                HStack(spacing: 0) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.aevis(17, weight: .semibold))
                            .foregroundStyle(theme.onBackground.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    // 换皮肤。放在右上这一排、**压得比别的控件淡**（0.55 不透明度），
                    // 看一眼能发现、但不抢戏 —— 它是个「偶尔想起来才用」的入口。
                    Button {
                        BlackBox.tap("播放器 · 换皮肤")
                        showThemePicker = true
                    } label: {
                        Image(systemName: "paintpalette")
                            .font(.aevis(16, weight: .semibold))
                            .foregroundStyle(theme.onBackground.opacity(0.55))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // 找歌。以前这块是个 `Color.clear` —— 只为了跟左边那个箭头等宽、
                    // 让歌名真的居中。现在正好拿它放放大镜：尺寸一样，居中不变，
                    // 白捡一个入口（而且是最需要的那个：一起听时想换歌）。
                    Button {
                        BlackBox.tap("播放器 · 找歌")
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.aevis(17, weight: .semibold))
                            .foregroundStyle(theme.onBackground.opacity(0.9))
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let track = player.current {
                Text(track.title)
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(theme.onBackground)
                    .lineLimit(1)

                Text(track.artist.isEmpty ? track.album : track.artist)
                    .font(.aevis(12.5))
                    .foregroundStyle(theme.onBackground.opacity(0.65))
                    .lineLimit(1)
            } else {
                Text("还没在放歌")
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(theme.onBackground)
            }

            // 两个人的头像**挪到上面来了**（用户 2026-10-31：把头像移到上面去）。
            // 原来它在最底下、压着功能行，得往下滑才看得见 ——
            // 而"一起听"最该一眼看到的就是这两个人。
            if together.active {
                compactTogetherRow
                    .padding(.top, 2)
            }
        }
        .padding(.top, 6)
    }

    /// 压缩版的一起听头像：小一圈、没名字。
    ///
    /// 用户要的是「压缩一下」—— 原来 44pt 一个还要带名字，
    /// 摆在歌名下面直接顶掉 60pt 高度，唱片就小了。这里 30pt、
    /// 名字只在 accessibility 里留一份。
    private var compactTogetherRow: some View {
        HStack(spacing: 10) {
            AevisAvatar(source: .me, size: 30, seed: persona.avatarSeed)
                .overlay(Circle().strokeBorder(theme.onBackground.opacity(0.30), lineWidth: 1))

            Image(systemName: "heart.fill")
                .font(.aevis(10))
                .foregroundStyle(theme.onBackground.opacity(0.55))

            AevisAvatar(source: .ai, size: 30, seed: persona.avatarSeed)
                .overlay(Circle().strokeBorder(theme.onBackground.opacity(0.30), lineWidth: 1))

            if together.thinking {
                Text("\(Pronoun.current)在想…")
                    .font(.aevis(10.5))
                    .foregroundStyle(theme.onBackground.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("你正在和\(persona.name.isEmpty ? "ta" : persona.name)一起听")
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
                    .fill(theme.primary.opacity(0.07))

                Circle()
                    .strokeBorder(theme.primary.opacity(0.14), lineWidth: 1)
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
                .fill(theme.primary.opacity(0.72))
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
                    theme.accent.opacity(0.95),
                    theme.accent.opacity(0.40)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.aevis(46, weight: .light))
                // 深色皮肤压白、浅色皮肤压深，跟那张彩色的假封面拉开对比。
                .foregroundStyle(
                    theme.forcesDark
                        ? Color.white.opacity(0.92)
                        : theme.onBackground.opacity(0.85)
                )
        }
    }

    // MARK: - 歌词 + ta的话

    /// **整屏滚动歌词**（2026-10-31 按用户截图5 加的）。
    ///
    /// 网易云的播放器歌词是一整屏往下滚、当前行放大高亮、其余淡着，
    /// 不是只显示当前行 + 下一行。所以这里改成 ScrollView。
    private var lyricArea: some View {
        VStack(spacing: 11) {
            let lines = player.scrollLyricLines
            if !lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 11) {
                            // 顶部留白：让第一行能滚到中间那个位置
                            Color.clear.frame(height: 92)

                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                let on = idx == (player.lyricCursor ?? -1)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.aevis(on ? 18 : 15, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on
                                                     ? theme.lyricDone
                                                     : theme.lyricWaiting)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id(idx)
                            }

                            Color.clear.frame(height: 120)
                        }
                        .padding(.horizontal, 22)
                    }
                    .onChange(of: player.lyricCursor) { _, cursor in
                        guard let cursor else { return }
                        // 滚到当前行 —— 用 anchor 把这一行顶到中间偏上。
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo(cursor, anchor: .center)
                        }
                    }
                }
                .frame(minHeight: 116)
            } else if player.current != nil {
                Text(player.lyric.isEmpty ? "这首歌没有歌词" : "前奏…")
                    .font(.aevis(17, weight: .medium))
                    .foregroundStyle(theme.onBackground.opacity(0.55))
            } else {
                // 空界面上的这句话**能点** —— 它说的就是"去找一首"，
                // 那就别让他再去找那个放大镜（右上角那个小图标不一定看得见）。
                Button {
                    BlackBox.tap("播放器 · 空界面点了找歌")
                    showSearch = true
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.aevis(20, weight: .medium))
                        Text("点这里找一首，或者跟 \(Pronoun.spaced(persona.pronoun)) 说「放首歌」")
                            .font(.aevis(14))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(theme.onBackground.opacity(0.66))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // ta刚说的那句。**不自动念** —— 想听点小喇叭。
            if let latest = together.herLines.first {
                HStack(alignment: .top, spacing: 8) {
                    AevisAvatar(source: .ai, size: 22, seed: persona.avatarSeed)

                    Text(latest)
                        .font(.aevis(13.5))
                        .foregroundStyle(theme.onBackground.opacity(0.9))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        together.speak(latest)
                    } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.aevis(12.5))
                            .foregroundStyle(theme.onBackground.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.onBackground.opacity(0.10))
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 116, alignment: .center)
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
            .tint(theme.primary.opacity(0.85))

            HStack(spacing: 8) {
                Text(Self.time(player.progress))
                Spacer(minLength: 8)
                Text(Self.time(player.duration))
            }
            .font(.aevisMono(10.5))
            .foregroundStyle(theme.onBackground.opacity(0.55))
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
                    // 图标取**底色**：深色皮肤的主色是白 → 图标是深色，
                    // 浅色皮肤的主色是近黑/玫粉 → 图标是浅色，两种都对得上。
                    .foregroundStyle(theme.background.opacity(0.85))
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(theme.primary.opacity(0.94)))
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
                .foregroundStyle(theme.onBackground.opacity(0.9))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部：一起听

    private var bottomArea: some View {
        VStack(spacing: 9) {
            // 网易云式功能行（2026-10-31 按用户截图5/6 加的）：
            // 红心 / 评论 / 语音 / 视频 / 分享 —— 五个**全部接的真接口**。
            neteaseActionRow

            if together.active {
                // 头像已经挪到上面去了（见 `compactTogetherRow`），
                // 这里只剩两个动作：打字聊、结束。
                //
                // ⚠️ 「让ta说一句」那个按钮**用户点名取消了** ——
                //    改成定时自己说（见 `ListenTogetherService.autoSpeakEnabled`）。
                //    留着一个要人戳才开口的按钮，等于把"ta在旁边"变成"ta是个点唱机"。
                HStack(spacing: 8) {
                    // 「打字聊」—— 用户 2026-09-30 点名的那个输入框。
                    // 摆在这一排的**第一个**：他说的是"不能互相打字聊天"，
                    // 那这就是这一排里最该先被看到的。
                    Button {
                        BlackBox.tap("播放器 · 打字聊")
                        showChat = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "keyboard")
                                .font(.aevis(12.5, weight: .medium))
                            Text("打字聊")
                                .font(.aevis(13, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(theme.onBackground.opacity(0.92))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.accent.opacity(0.55)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        together.stop()
                        say("这一场一起听到这儿")
                    } label: {
                        Text("结束")
                            .font(.aevis(13))
                            .lineLimit(1)
                            .foregroundStyle(theme.onBackground.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(theme.onBackground.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
            } else {
                // ⚠️ 这里原来是一个「同步听 / ta控制 / 一起听房间」的**形态选择器**。
                //
                //    2026-10-02 用户点名删掉：
                //    「一点进去，不是有一个ta控制，然后网易云一起听吗？那个就不要了」。
                //
                //    删得对 —— 那三个不是三种体验，是同一个体验的三个完成度：
                //    「一起听房间」压根没接（界面上还写着"还没接"），
                //    「ta控制」的唯一实际效果是**让ta整场不说话**。
                //    现在只剩一种，就没必要让他挑。这一句说明代替它。
                Text("歌从这儿放，\(Pronoun.current)跟着一起听 —— 想切歌、暂停，直接跟\(Pronoun.current)说就行。")
                    .font(.aevis(11.5))
                    .foregroundStyle(theme.onBackground.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $settings.listenTogetherAutoStart) {
                    Text("放歌就一起听")
                        .font(.aevis(13))
                        .foregroundStyle(theme.onBackground.opacity(0.75))
                }
                .tint(theme.accent)

                Button {
                    startTogether()
                } label: {
                    Text(settings.isConfigured ? "现在就开始一起听" : "要填了 API Key \(Pronoun.current)才会说话")
                        .font(.aevis(13, weight: .medium))
                        .foregroundStyle(theme.onBackground.opacity(settings.isConfigured ? 0.9 : 0.45))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(theme.onBackground.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(!settings.isConfigured)
            }

            if let status = together.statusLine {
                Text(status)
                    .font(.aevis(11.5))
                    .foregroundStyle(theme.onBackground.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - 网易云式功能行

    /// 网易云播放器最下面那一排（截图5/6）：红心 / 评论 / 语音 / 视频 / 分享。
    ///
    /// 五个**全部是真实功能**，没有占位按钮：
    /// - **红心** → 加进「我喜欢的音乐」（`NeteaseClient.like`）
    /// - **评论** → 拉这首歌的真实网易云评论（`NeteaseClient.comments`）
    /// - **语音** → 跟 ta 说话（退到打字聊，语音版还在排期）
    /// - **视频** → 这首歌的 MV（`NeteaseClient.mvURL` → AVPlayer）
    /// - **分享** → 分享给 AI（`together.send`，两边都落进正式聊天记录）
    private var neteaseActionRow: some View {
        HStack(spacing: 0) {
            actionButton(icon: likedNow ? "heart.fill" : "heart",
                         tint: likedNow ? .red : theme.onBackground.opacity(0.85),
                         label: "红心") {
                Task { await toggleLike() }
            }

            actionButton(icon: "bubble.left.and.bubble.right.fill",
                         tint: theme.onBackground.opacity(0.85),
                         label: "评论") {
                guard player.current != nil else { return }
                BlackBox.tap("播放器 · 评论")
                showComments = true
            }

            actionButton(icon: "mic.fill",
                         tint: theme.onBackground.opacity(0.85),
                         label: "语音") {
                say("语音还没做好，先用打字聊")
                showChat = true
            }

            actionButton(icon: "play.rectangle.fill",
                         tint: theme.onBackground.opacity(0.85),
                         label: "视频") {
                Task { await openMV() }
            }

            actionButton(icon: "paperplane.fill",
                         tint: theme.onBackground.opacity(0.85),
                         label: "分享") {
                shareCurrentToAI()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func actionButton(icon: String, tint: Color,
                              label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.aevis(18))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.aevis(9.5))
                    .foregroundStyle(theme.onBackground.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(player.current == nil)
        .opacity(player.current == nil ? 0.4 : 1)
    }

    private func say(_ text: String) {
        note = text
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { note = nil }
        }
    }

    private func toggleLike() async {
        guard let track = player.current else { return }
        do {
            try await NeteaseClient.shared.like(songID: track.id)
            likedNow = true
            say("已加进「我喜欢的音乐」")
        } catch {
            say("红心没成功：\(error.localizedDescription)")
        }
    }

    // MARK: - 视频（这首歌的 MV）

    /// 打开这首歌的 MV。
    ///
    /// 链路是 `/api/v3/song/detail` 拿 `mv` id → `/api/song/enhance/play/mv/url`
    /// 拿 mp4 地址 → 系统播放器。**全是直连网易，不经过我们的服务器。**
    private func openMV() async {
        guard let track = player.current else { return }
        BlackBox.tap("播放器 · 视频")
        say("正在找这首歌的 MV…")
        do {
            let result = try await NeteaseClient.shared.mvURL(songID: track.id)
            note = nil
            mv = MVRequest(url: result.url,
                           title: result.title.isEmpty ? track.title : result.title)
        } catch {
            say(error.localizedDescription)
        }
    }

    /// 把正在听的歌**分享给 AI** —— 用户点名要的「分享就是分享给 AI」。
    ///
    /// 走 `together.send` 这条路而不是自己拼一条消息：
    /// 它会把这句话同时写进**正式聊天记录**（关掉播放器之后这段不会凭空消失），
    /// 还带着"正在听什么"一起交给模型，让 ta 真的接着这首歌聊。
    private func shareCurrentToAI() {
        guard let track = player.current else { return }
        BlackBox.tap("播放器 · 分享给 AI")
        let text = "我在听《\(track.title)》"
            + (track.artist.isEmpty ? "" : " - \(track.artist)")
            + "，跟我聊聊这首歌"
        say("已分享给\(Pronoun.current)")
        // 没在一起听就先开起来 —— 否则 `together.send` 手上没有模型配置，
        // 这句话会石沉大海（只剩聊天记录里一行，ta 永远不会回）。
        if !together.active { startTogether() }
        Task { await together.send(text) }
    }

    // MARK: - 一起听

    /// 打开播放器就顺手开始一起听 —— 用户要的「默认一起听」。
    ///
    /// 两个前提缺一不可，否则ta会一直报错或者干脆不说话：
    /// 开关开着、模型配好了。
    ///
    /// ⚠️ 以前还有第三道 `guard mode.isImplemented` —— 形态选择器删掉之后
    ///    就没有"没实现的形态"这回事了，那道守卫跟着一起删。
    private func autoStartTogether() {
        guard settings.listenTogetherAutoStart else { return }
        guard !together.active, player.current != nil else { return }
        startTogether()
    }

    private func startTogether() {
        guard !together.active else { return }
        guard settings.isConfigured else { return }

        together.start(
            persona: persona,
            config: settings.llm,
            memory: backgroundKnowledge()
        )
    }

    /// 给ta的背景资料 —— **和聊天页同一套口径**（ta那边有详细注释）。
    ///
    /// 以前这里只给长期记忆，于是"一起听"时ta不知道你们的纪念日、
    /// 不知道现在几点、在哪儿 —— 说话就比聊天页里那个ta**笨一截**。
    /// 同一个人不该因为换了个页面就变得不认得你。
    private func backgroundKnowledge() -> [String] {
        var context = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        // 情侣空间（在一起多少天 / 倒数日）**不挂记忆开关** ——
        // 那是用户手填的硬事实，关掉记忆不等于让ta忘了纪念日。
        context.append(contentsOf: CoupleStore.shared.injectedLines())
        let screenTime = ScreenTimeInsight.shared.digest()
        if !screenTime.isEmpty { context.append(screenTime) }
        context.append(contentsOf: AmbientContext.shared.digest())
        return context
    }

    // MARK: - 皮肤

    /// 换皮肤：先改本地状态（视图立刻重绘），再写盘（下次进来还是这套）。
    ///
    /// 顺序不能反 —— 先写盘的话，万一 `@State` 没更新，界面就停在旧皮肤上了。
    private func applyTheme(_ newTheme: PlayerTheme) {
        BlackBox.tap("播放器 · 换皮肤 · \(newTheme.name)")
        theme = newTheme
        PlayerTheme.set(newTheme)
    }

    // MARK: - 零件

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
