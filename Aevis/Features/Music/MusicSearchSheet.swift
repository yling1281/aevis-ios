import SwiftUI

/// 音乐面板 —— **可复用的那一份**。
///
/// ## 它有四页（2026-10-02 加的后面三页）
///
/// 用户原话：「网易云音乐的话，就是他的喜欢、历史歌单、和他添加的歌单都加上」。
///
/// 以前这里只有「搜」，而他又要的是"我自己那些歌"—— 那是**另一件事**：
/// 搜是"我知道要听什么"，我的音乐是"我不知道听什么，你把我有的摆出来"。
/// 所以上面加了一条分页：找歌 / 我喜欢 / 最近 / 歌单。
///
/// ## 为什么把搜索抽出来（2026-10-01）
/// 用户原话：「现在的『一起听』不好用」。
///
/// 一半的原因在这儿：**搜索只长在「音乐」页里**。人在全屏播放界面上想换首歌，
/// 得先退出去、翻到「音乐」、搜完点一首，播放器再重新弹 —— 中间那一下
/// 一起听还会断掉。这不是"不好用"，这是根本用不了。
///
/// 所以把搜索抽成一块独立的，谁都能挂：
/// - `PlayerView` 右上角的放大镜（一起听时随手换歌）
/// - 想单独用也行（它自带 `NavigationStack`）
///
/// ## 行为
/// 点一行 → 交给 `onPick`；没给 `onPick` 就**直接放 + 自动收起**
/// （跟网易云一样：点了就进播放界面，不该还要再点一次"确定"）。
struct MusicSearchSheet: View {

    /// 上面那条分页。
    enum Panel: String, CaseIterable, Identifiable {
        case search
        case liked
        case recent
        case playlists

        var id: String { rawValue }

        var label: String {
            switch self {
            case .search: return "找歌"
            case .liked: return "我喜欢"
            case .recent: return "最近"
            case .playlists: return "歌单"
            }
        }
    }

    /// 选了一首之后干什么。
    ///
    /// 传 nil = 用默认行为（真的去放，然后把这个面板收起来）。
    /// 之所以留这个口子：以后「一起听」想换成"只加入队列不立刻切歌"就在这儿改。
    var onPick: ((_ queue: [MusicTrack], _ index: Int) -> Void)?

    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var panel: Panel = .search

    @State private var keyword = ""
    @State private var results: [MusicTrack] = []
    @State private var searching = false
    @State private var note: String?

    // ---- 「我的音乐」那三页 ----
    /// 当前页要显示的那批歌（喜欢 / 最近 / 某个歌单里的）。
    @State private var library: [MusicTrack] = []
    /// 我的歌单列表（歌单页用）。
    @State private var playlists: [NeteasePlaylist] = []
    /// 正在拉数据 —— **必须有**：没它的话切到"最近"会先闪一下"空"再出歌。
    @State private var loadingLibrary = false
    @State private var libraryNote: String?
    /// 已经点进去的那个歌单。非 nil 时歌单页显示的是它的曲目。
    @State private var opened: NeteasePlaylist?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if NeteaseClient.shared.isLoggedIn {
                    Picker("", selection: $panel) {
                        ForEach(Panel.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !NeteaseClient.shared.isLoggedIn {
                            needLoginCard
                        } else {
                            switch panel {
                            case .search:           searchPanel
                            case .liked, .recent:   trackPanel
                            case .playlists:        playlistsPanel
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .navigationTitle("音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        // ⚠️ `.task(id:)` 在**出现时也会跑一次**，所以切页和首次进面板是同一段逻辑。
        .task(id: panel) { await loadCurrentPanel() }
    }

    // MARK: - 分页内容

    @ViewBuilder
    private var searchPanel: some View {
        searchCard
        if !results.isEmpty { trackCard(results, title: "结果") }
    }

    @ViewBuilder
    private var trackPanel: some View {
        if loadingLibrary {
            loadingCard
        } else if let libraryNote {
            noteCard(libraryNote)
        } else if library.isEmpty {
            noteCard(panel == .liked ? "还没有红心过任何歌。" : "最近播放是空的。")
        } else {
            trackCard(library, title: panel == .liked ? "我喜欢的音乐" : "最近播放")
        }
    }

    @ViewBuilder
    private var playlistsPanel: some View {
        if let opened {
            // 点进去了 —— 上面一行"返回"，下面就是它的曲目。
            Button {
                self.opened = nil
                library = []
                libraryNote = nil
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.aevis(12, weight: .semibold))
                    Text("返回歌单")
                        .font(.aevis(13.5))
                }
                .foregroundStyle(settings.accentColor)
            }
            .buttonStyle(.plain)

            if loadingLibrary {
                loadingCard
            } else if let libraryNote {
                noteCard(libraryNote)
            } else if library.isEmpty {
                noteCard("这个歌单里还没有歌。")
            } else {
                trackCard(library, title: displayName(for: opened))
            }
        } else if loadingLibrary {
            loadingCard
        } else if let libraryNote {
            noteCard(libraryNote)
        } else if playlists.isEmpty {
            noteCard("你还没有任何歌单。")
        } else {
            playlistCard
        }
    }

    // MARK: - 搜索

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("歌名、歌手、或者一句歌词", text: $keyword)
                    .font(.aevis(14.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )

                Button(action: runSearch) {
                    HStack(spacing: 6) {
                        if searching {
                            ProgressView().controlSize(.small)
                        }
                        Text(searching ? "找…" : "搜")
                            .font(.aevis(14, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
                }
                .disabled(searching)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await loadDaily() }
                } label: {
                    Text("每日推荐")
                        .font(.aevis(13.5))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 13)
                }
                .disabled(searching)

                Spacer(minLength: 0)
            }

            if let note {
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var needLoginCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没登录网易云")
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)
            Text("去「发现 → 音乐」登录一次就够了，凭据存在本机钥匙串里。登录完再回来搜。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 通用小块

    private var loadingCard: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("正在拉…")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func noteCard(_ text: String) -> some View {
        Text(text)
            .font(.aevis(13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 曲目列表

    /// 一批歌。**四处都用它**（搜索结果 / 喜欢 / 最近 / 某个歌单）——
    /// 以前只有搜索结果那一份，加一页就得复制一段，那是"同一个东西写两遍"。
    private func trackCard(_ tracks: [MusicTrack], title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("全部播放") {
                    pick(tracks, 0)
                }
                .font(.aevis(13))
                .foregroundStyle(settings.accentColor)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // ⚠️ 唯一标识用**序号**，不用曲目 id —— 网易的搜索结果里
            // 偶尔同一个 id 出现两次（不同版本/音质条目），重复 id 在 SwiftUI
            // 里是未定义行为。这条在 `MusicView` 里踩过，这里照抄结论。
            ForEach(Array(tracks.prefix(100).enumerated()), id: \.offset) { index, track in
                Button {
                    pick(tracks, index)
                } label: {
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.aevisMono(11.5))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, alignment: .trailing)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.aevis(14.5))
                                .foregroundStyle(
                                    player.current?.id == track.id ? settings.accentColor : .primary
                                )
                                .lineLimit(1)
                            Text(track.display)
                                .font(.aevis(11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        if player.current?.id == track.id, player.isPlaying {
                            Image(systemName: "waveform")
                                .font(.system(size: 13))
                                .foregroundStyle(settings.accentColor)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 歌单列表

    private var playlistCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(orderedPlaylists) { item in
                Button {
                    Task { await open(item) }
                } label: {
                    HStack(spacing: 11) {
                        playlistCover(item)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(displayName(for: item))
                                    .font(.aevis(14.5))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                // 「ta的歌单」要一眼认出来 —— 它在网易云里就是一个
                                // 普通歌单，不给个标记的话它跟别的没区别。
                                if isHer(item) {
                                    Text("\(Pronoun.current)的")
                                        .font(.aevis(10, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(settings.accentColor))
                                } else if item.isLiked {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(settings.accentColor)
                                }
                            }

                            Text(subtitle(for: item))
                                .font(.aevis(11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.aevis(12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .aevisGlass(cornerRadius: 18)
    }

    /// 歌单封面。
    ///
    /// ⚠️ 尺寸兜底（`.frame` + `.clipShape`）**必须紧跟在 AsyncImage 后面**。
    ///    第一版把 `.frame` 写在 `Color.clear` 上、图放 `.overlay` 里，
    ///    `scaledToFill` 离兜底隔了十几行 —— 功能上没坏，但 R3 那条检查器
    ///    只往回看 6 行，于是报了警。要么改检查器、要么改代码；
    ///    这一处**改代码更对**（图就是 42×42 的方块，本来就该这么写）。
    private func playlistCover(_ item: NeteasePlaylist) -> some View {
        AsyncImage(url: item.coverURL) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                fallbackCover(item)
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// 没封面时那个占位方块。
    private func fallbackCover(_ item: NeteasePlaylist) -> some View {
        ZStack {
            settings.accentColor.opacity(0.25)
            Image(systemName: item.isLiked ? "heart.fill" : "music.note.list")
                .font(.system(size: 15))
                .foregroundStyle(settings.accentColor)
        }
    }

    private func subtitle(for item: NeteasePlaylist) -> String {
        var parts: [String] = []
        if item.trackCount > 0 { parts.append("\(item.trackCount) 首") }
        if isHer(item) { parts.append("\(Pronoun.current)自己收藏的") }
        else if item.isLiked { parts.append("我喜欢的音乐") }
        else if !item.isMine { parts.append("收藏的歌单") }
        return parts.isEmpty ? "歌单" : parts.joined(separator: " · ")
    }

    /// 列表里的排序：**ta的歌单最前**，然后是「我喜欢的音乐」，剩下的按原顺序。
    ///
    /// 不排序的话ta的歌单会按网易返回的顺序埋在中间 —— 而这一页存在的
    /// 一半理由就是"看看ta藏了什么"。
    private var orderedPlaylists: [NeteasePlaylist] {
        let hers = playlists.filter { isHer($0) }
        let liked = playlists.filter { !isHer($0) && $0.isLiked }
        let rest = playlists.filter { !isHer($0) && !$0.isLiked }
        return hers + liked + rest
    }

    private func isHer(_ item: NeteasePlaylist) -> Bool {
        item.name == HerPlaylist.realName(for: personaStore.persona)
    }

    /// 界面上的名字 —— ta的那张**不显示网易云里的真名**。
    private func displayName(for item: NeteasePlaylist) -> String {
        isHer(item) ? HerPlaylist.displayName(for: personaStore.persona) : item.name
    }

    // MARK: - 动作

    private func pick(_ queue: [MusicTrack], _ index: Int) {
        guard queue.indices.contains(index) else { return }
        if let onPick {
            onPick(queue, index)
        } else {
            Task { @MainActor in
                await player.play(queue: queue, index: index)
                dismiss()
            }
        }
    }

    private func runSearch() {
        let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !searching else { return }
        searching = true
        note = nil

        Task { @MainActor in
            do {
                results = try await NeteaseClient.shared.search(text)
                if results.isEmpty { note = "没搜到「\(text)」。" }
            } catch {
                note = error.localizedDescription
            }
            searching = false
        }
    }

    /// ⚠️ `@MainActor` 不能省：`Task { await … }` 只把**调用点**放在主 actor 上，
    /// `await` 之后函数体会跑回全局并发池 —— 那样就是在后台线程写 `@State`。
    @MainActor
    private func loadDaily() async {
        searching = true
        note = nil
        do {
            results = try await NeteaseClient.shared.dailyRecommend()
            note = "每日推荐拿到 \(results.count) 首。"
        } catch {
            note = error.localizedDescription
        }
        searching = false
    }

    /// 切页（以及第一次进来）时把这一页的数据拉出来。
    @MainActor
    private func loadCurrentPanel() async {
        guard NeteaseClient.shared.isLoggedIn else { return }
        libraryNote = nil

        switch panel {
        case .search:
            return

        case .liked:
            opened = nil
            loadingLibrary = true
            do { library = try await NeteaseClient.shared.likedTracks() }
            catch {
                library = []
                libraryNote = error.localizedDescription
            }
            loadingLibrary = false

        case .recent:
            opened = nil
            loadingLibrary = true
            do { library = try await NeteaseClient.shared.recentTracks(limit: 100) }
            catch {
                library = []
                // 未登录 / Cookie 过期在这里是最常见的失败 —— 照实显示，
                // 别让这一页永远转圈。
                libraryNote = error.localizedDescription
            }
            loadingLibrary = false

        case .playlists:
            opened = nil
            library = []
            loadingLibrary = true
            do { playlists = try await NeteaseClient.shared.myPlaylists() }
            catch {
                playlists = []
                libraryNote = error.localizedDescription
            }
            loadingLibrary = false
        }
    }

    /// 点进一个歌单，把里面的曲目拉出来。
    @MainActor
    private func open(_ playlist: NeteasePlaylist) async {
        opened = playlist
        library = []
        libraryNote = nil
        loadingLibrary = true
        do { library = try await NeteaseClient.shared.playlistDetail(playlist.id) }
        catch { libraryNote = error.localizedDescription }
        loadingLibrary = false
    }
}
