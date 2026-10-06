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

    private var lyricArea: some View {
        VStack(spacing: 11) {
            if let line = player.currentLyricLine {
                Text(line)
                    .font(.aevis(21, weight: .semibold))
                    .foregroundStyle(theme.lyricDone)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let next = player.nextLyricLine {
                    Text(next)
                        .font(.aevis(14))
                        .foregroundStyle(theme.lyricWaiting)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: - 两个人的头像

    /// 一起听开着才出现 —— 你在左、ta 在右。
    private var togetherRow: some View {
        HStack(spacing: 16) {
            avatarSlot(source: .me, title: "我")
            Image(systemName: "heart.fill")
                .font(.aevis(13))
                .foregroundStyle(theme.onBackground.opacity(0.7))
            avatarSlot(source: .ai, title: persona.name.isEmpty ? "ta" : persona.name)
        }
    }

    private func avatarSlot(source: AevisAvatar.Source, title: String) -> some View {
        VStack(spacing: 5) {
            AevisAvatar(source: source, size: 44, seed: persona.avatarSeed)
                .overlay(Circle().strokeBorder(theme.onBackground.opacity(0.35), lineWidth: 1.5))
            Text(title)
                .font(.aevis(10.5))
                .foregroundStyle(theme.onBackground.opacity(0.7))
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
        VStack(spacing: 11) {
            if together.active {
                togetherRow

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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.accent.opacity(0.55)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await together.pokeHer() }
                    } label: {
                        Text(together.thinking ? "\(Pronoun.current)在想…" : "让\(Pronoun.current)说一句")
                            .font(.aevis(13, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(theme.onBackground.opacity(0.9))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(theme.onBackground.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .disabled(together.thinking)

                    Button {
                        together.stop()
                    } label: {
                        Text("结束")
                            .font(.aevis(13))
                            .lineLimit(1)
                            .foregroundStyle(theme.onBackground.opacity(0.65))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(theme.onBackground.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
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
