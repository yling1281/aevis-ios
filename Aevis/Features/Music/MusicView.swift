import SwiftUI

/// 音乐页 —— **网易云官方那种界面**（2026-10-31 按用户截图重做）。
///
/// ## 为什么改成这样
/// 用户给了三张网易云 App 的截图（排行榜 / 我的 / 搜索），要的就是这个布局：
/// 顶上品牌栏 + 搜索框，下面三个 Tab：
/// - **排行榜**：三列宫格，每格一个彩色渐变方块 + 榜单名（截图1）
/// - **我的**：头像昵称 + 每日推荐 + 我喜欢的音乐 + 我的歌单列表（截图2）
/// - **搜索**：空态提示「输入关键词，搜索网易云曲库」（截图3）
///
/// ## ⚠️ 数据从哪来
/// **全部直连 `music.163.com`**，不经过我们的服务器、不做反向代理 ——
/// 小程序过不了审，APP 也不该把我们的机器当网易云的中转。
/// `NeteaseClient` 本来就是这么连的（`base = "https://music.163.com"`）。
///
/// ## 保留了原来的东西
/// 登录（扫码/贴 Cookie）、找歌、全屏播放器 —— 都在，只是位置变了：
/// 登录进了「我的」Tab，找歌进了顶栏的搜索框。
struct MusicView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var player = MusicPlayer.shared
    /// 网易云客户端是普通单例（不是 ObservableObject），所以不能用 `@ObservedObject`。
    /// 登录状态变化靠 `AppSettings`（settings 是 ObservedObject）带动刷新。
    private let netease = NeteaseClient.shared

    /// 点一首歌就弹全屏播放器 —— 和网易云一样，点了直接进播放界面。
    @ObservedObject private var router = AppRouter.shared

    @State private var note: String? = nil
    @State private var editingCookie = false
    @State private var cookieDraft = ""
    @State private var showLogin = false
    @State private var showSearch = false
    /// 三个 Tab：排行榜 / 我的 / 搜索
    @State private var tab: MusicTab = .rank
    /// 榜单数据（懒加载，进了「排行榜」才拉）
    @State private var ranks: [NeteaseRank] = []
    @State private var ranksLoading = false
    @State private var ranksFailed = false
    /// 「我的」Tab 的歌单
    @State private var myPlaylists: [NeteasePlaylist] = []
    @State private var playlistsLoading = false
    /// 当前网易云账号（昵称 / 头像）
    @State private var account: NeteaseAccount? = nil
    /// 音乐源：网易云 / Apple Music
    @State private var provider: MusicProvider = .netease

    enum MusicTab: String, CaseIterable, Identifiable {
        case rank, mine, search
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rank: return "排行榜"
            case .mine: return "我的"
            case .search: return "搜索"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if provider == .netease {
                brandBar
                tabBar
                content
            } else {
                AppleMusicView()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if provider == .netease {
                    Text("音乐").font(.aevis(17, weight: .semibold))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        provider = .netease
                    } label: {
                        Label("网易云", systemImage: provider == .netease ? "checkmark" : "music.note")
                    }
                    Button {
                        provider = .apple
                    } label: {
                        Label("Apple Music", systemImage: provider == .apple ? "checkmark" : "apple.logo")
                    }
                } label: {
                    Image(systemName: provider == .netease ? "music.note" : "apple.logo")
                        .font(.aevis(14, weight: .medium))
                }
            }
        }
        .sheet(isPresented: $showLogin) {
            NeteaseLoginView()
        }
        .sheet(isPresented: $showSearch) {
            MusicSearchSheet()
        }
        .alert("网易云 Cookie", isPresented: $editingCookie) {
            TextField("MUSIC_U=...; 或整段 Cookie", text: $cookieDraft)
            Button("保存") {
                NeteaseClient.shared.setCookie(cookieDraft)
                note = NeteaseClient.shared.isLoggedIn
                    ? "Cookie 存好了（在钥匙串里，不会外传）。"
                    : "这段里没找到 MUSIC_U=，可能贴错了。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("在浏览器里登录网易云音乐，打开开发者工具 → Application → Cookies，把 music.163.com 那一段整个复制过来。")
        }
        .onAppear { if provider == .netease { loadRanks() } }
        .onChange(of: provider) { _, new in
            if new == .netease { loadRanks() }
        }
        .onChange(of: tab) { _, new in
            if new == .mine { loadMine() }
        }
    }

    // MARK: - 顶栏（品牌 + 搜索框）

    private var brandBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.down")
                    .font(.aevis(15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .contentShape(Circle())
                    .onTapGesture { router.showPlayer = false }

                Spacer(minLength: 0)

                VStack(spacing: 1) {
                    Text("NETEASE CLOUD MUSIC")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.6)
                        .foregroundStyle(Color(red: 0.9, green: 0.13, blue: 0.18))
                    Text("网易云")
                        .font(.aevis(19, weight: .bold))
                        .foregroundStyle(.primary)
                }

                Spacer(minLength: 0)

                Image(systemName: "ellipsis")
                    .font(.aevis(15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
                    .contentShape(Circle())
                    .onTapGesture { note = "这里以后放更多入口" }
            }
            .padding(.horizontal, 16)

            // 搜索框（点一下进搜索 Tab 的搜索面板）
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.aevis(14))
                    .foregroundStyle(.secondary)
                Text("搜索歌曲、歌手")
                    .font(.aevis(14.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(Circle().fill(Color(.secondarySystemGroupedBackground)))
            .contentShape(Rectangle())
            .onTapGesture {
                tab = .search
                showSearch = true
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [Color(red: 1, green: 0.93, blue: 0.93),
                         Color(red: 1, green: 0.96, blue: 0.96)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Tab 栏

    private var tabBar: some View {
        HStack(spacing: 24) {
            ForEach(MusicTab.allCases) { t in
                Button {
                    tab = t
                    if t == .rank { loadRanks() }
                    if t == .mine { loadMine() }
                } label: {
                    VStack(spacing: 6) {
                        Text(t.title)
                            .font(.aevis(15, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? .primary : .secondary)
                        Rectangle()
                            .fill(Color(red: 0.9, green: 0.13, blue: 0.18))
                            .frame(width: 18, height: 2.5)
                            .opacity(tab == t ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .background(Color(red: 1, green: 0.96, blue: 0.96))
    }

    // MARK: - 内容区

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .rank: rankTab
        case .mine: mineTab
        case .search: searchTab
        }
    }

    // MARK: - 排行榜（截图1）

    private var rankTab: some View {
        ScrollView {
            if ranksLoading && ranks.isEmpty {
                ProgressView().padding(.top, 60)
            } else if ranksFailed && ranks.isEmpty {
                failBox("榜单没拉下来") { loadRanks(force: true) }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                          spacing: 16) {
                    ForEach(ranks) { rank in
                        rankCard(rank)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
        }
    }

    private func rankCard(_ rank: NeteaseRank) -> some View {
        Button {
            Task { await openRank(rank) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    LinearGradient(
                        colors: [Color(rgb: rank.tint.top), Color(rgb: rank.tint.bottom)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    if let cover = rank.coverURL {
                        AsyncImage(url: cover) { img in
                            img.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.clear
                        }
                        .opacity(0.55)
                    }
                    Text(rank.name)
                        .font(.aevis(15, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(rank.name)
                    .font(.aevis(12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 我的（截图2）

    private var mineTab: some View {
        ScrollView {
            VStack(spacing: 0) {
                if !netease.isLoggedIn {
                    // 未登录：点一下去登录
                    Button {
                        showLogin = true
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color(red: 0.9, green: 0.13, blue: 0.18))
                                Image(systemName: "music.note")
                                    .font(.aevis(19))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 48, height: 48)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("点击登录")
                                    .font(.aevis(15, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("登录后查看你的歌单")
                                    .font(.aevis(12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.aevis(12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    profileRow
                    dailyCard
                    likedCard
                }

                // 我的歌单列表
                if playlistsLoading {
                    ProgressView().padding(.top, 30)
                } else if !myPlaylists.isEmpty {
                    LazyVStack(spacing: 9) {
                        ForEach(myPlaylists) { pl in
                            playlistRow(pl)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }

                if let note {
                    Text(note)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }

                riskNote.padding(.horizontal, 14).padding(.top, 20)
            }
            .padding(.bottom, 28)
        }
    }

    private var profileRow: some View {
        HStack(spacing: 12) {
            AsyncImage(url: account?.avatarURL) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(Color(.tertiarySystemFill))
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(account?.nickname ?? "网易云用户")
                    .font(.aevis(15.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text("网易云账号")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.aevis(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var dailyCard: some View {
        menuCard(icon: "square.grid.3x3.fill",
                 iconColors: [Color(red: 1, green: 0.42, blue: 0.42),
                              Color(red: 0.88, green: 0.13, blue: 0.13)],
                 title: "每日推荐",
                 sub: "根据你的口味，每天更新") {
            Task { await openDaily() }
        }
    }

    private var likedCard: some View {
        menuCard(icon: "heart.fill",
                 iconColors: [Color(red: 1, green: 0.48, blue: 0.48),
                              Color(red: 0.89, green: 0.2, blue: 0.2)],
                 title: "我喜欢的音乐",
                 sub: likedCountText) {
            Task { await openLiked() }
        }
    }

    /// 「我喜欢的音乐」有多少首 —— 有歌单才算得出，没有就显示「登录后可见」。
    private var likedCountText: String {
        guard let liked = myPlaylists.first(where: { $0.isLiked }) else {
            return "登录后可见"
        }
        return "\(liked.trackCount) 首"
    }

    private func menuCard(icon: String, iconColors: [Color],
                          title: String, sub: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    LinearGradient(colors: iconColors,
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon)
                        .font(.aevis(18))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(sub)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(13)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
    }

    private func playlistRow(_ pl: NeteasePlaylist) -> some View {
        Button {
            Task { await openPlaylist(pl) }
        } label: {
            HStack(spacing: 11) {
                AsyncImage(url: pl.coverURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(pl.name)
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(pl.trackCount) 首")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(11)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 搜索（截图3）

    private var searchTab: some View {
        VStack(spacing: 0) {
            if player.current == nil {
                VStack(spacing: 0) {
                    Spacer()
                    Text("输入关键词，搜索网易云曲库")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                // 正在放着的时候显示播放条（和网易云一致）
                nowPlayingBar.padding(.horizontal, 14).padding(.top, 12)
            }
        }
    }

    private var nowPlayingBar: some View {
        Button {
            router.showPlayer = true
        } label: {
            HStack(spacing: 11) {
                AsyncImage(url: player.current?.coverURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "")
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(player.current?.display ?? "")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.aevis(24))
                        .foregroundStyle(Color(red: 0.9, green: 0.13, blue: 0.18))
                }
                .buttonStyle(.plain)
            }
            .padding(11)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var riskNote: some View {
        Text("这是逆向接入，没有官方接口 —— 网易改协议就可能失效，并且存在账号被风控的风险。建议登录一个不常用的小号。")
            .font(.aevis(11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func failBox(_ text: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.aevis(13.5))
                .foregroundStyle(.secondary)
            Button("再试一次", action: retry)
                .font(.aevis(14, weight: .medium))
                .foregroundStyle(Color(red: 0.9, green: 0.13, blue: 0.18))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - 数据

    private func loadRanks(force: Bool = false) {
        if !ranks.isEmpty, !force { return }
        ranksLoading = true
        ranksFailed = false
        Task {
            do {
                let list = try await netease.topLists()
                await MainActor.run {
                    ranks = list
                    ranksLoading = false
                    ranksFailed = list.isEmpty
                }
            } catch {
                await MainActor.run {
                    ranksLoading = false
                    ranksFailed = true
                }
            }
        }
    }

    private func loadMine() {
        guard netease.isLoggedIn else { return }
        guard myPlaylists.isEmpty, !playlistsLoading else { return }
        playlistsLoading = true
        Task {
            do {
                async let acc = netease.account()
                async let pls = netease.myPlaylists()
                let (a, list) = try await (acc, pls)
                await MainActor.run {
                    account = a
                    myPlaylists = list
                    playlistsLoading = false
                }
            } catch {
                await MainActor.run { playlistsLoading = false }
            }
        }
    }

    private func openRank(_ rank: NeteaseRank) async {
        do {
            let tracks = try await netease.playlistDetail(rank.id)
            guard !tracks.isEmpty else { note = "这个榜现在是空的"; return }
            await player.play(tracks, startingAt: 0)
            router.showPlayer = true
        } catch {
            note = "打不开这个榜：\(error.localizedDescription)"
        }
    }

    private func openPlaylist(_ pl: NeteasePlaylist) async {
        do {
            let tracks = try await netease.playlistDetail(pl.id)
            guard !tracks.isEmpty else { note = "这个歌单现在是空的"; return }
            await player.play(tracks, startingAt: 0)
            router.showPlayer = true
        } catch {
            note = "打不开这个歌单：\(error.localizedDescription)"
        }
    }

    private func openDaily() async {
        do {
            let tracks = try await netease.dailyRecommend()
            await player.play(tracks, startingAt: 0)
            router.showPlayer = true
        } catch {
            note = "每日推荐暂时拿不到：\(error.localizedDescription)"
        }
    }

    private func openLiked() async {
        do {
            let tracks = try await netease.likedTracks()
            guard !tracks.isEmpty else { note = "「我喜欢的音乐」还是空的"; return }
            await player.play(tracks, startingAt: 0)
            router.showPlayer = true
        } catch {
            note = "拿不到「我喜欢的音乐」：\(error.localizedDescription)"
        }
    }
}

// MARK: - 颜色工具

extension Color {
    /// 从 RGB 结构体建颜色（`NeteaseRank.tint` 用的是 RGB 不是 Color）。
    init(rgb: RGB) {
        self.init(.sRGB,
                  red: Double(rgb.r) / 255.0,
                  green: Double(rgb.g) / 255.0,
                  blue: Double(rgb.b) / 255.0,
                  opacity: 1)
    }
}

/// 音乐源：网易云（逆向接入）或 Apple Music（系统 MusicKit）。
enum MusicProvider: String, CaseIterable, Identifiable {
    case netease
    case apple
    var id: String { rawValue }
    var title: String {
        switch self {
        case .netease: return "网易云"
        case .apple: return "Apple Music"
        }
    }
}
