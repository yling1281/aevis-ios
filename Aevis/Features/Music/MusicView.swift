import SwiftUI

/// 音乐页：登录、搜歌、播放。
///
/// 登录有两条路：
/// 1. **在 App 里登录**（推荐）—— 登进去之后凭据自动从 cookie 里抓过来，
///    不用复制任何东西。之前只有第 2 条路，用户反馈「粘贴给他，他又说没有用」。
/// 2. 手动贴 Cookie —— 兜底，给习惯自己动手的人。
struct MusicView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var player = MusicPlayer.shared

    /// 点一首歌就弹全屏播放器 —— 和网易云一样，点了直接进播放界面。
    @ObservedObject private var router = AppRouter.shared

    @State private var keyword = ""
    @State private var results: [MusicTrack] = []
    @State private var searching = false
    @State private var note: String?
    @State private var editingCookie = false
    @State private var cookieDraft = ""
    @State private var showLogin = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                loginCard
                if NeteaseClient.shared.isLoggedIn {
                    searchCard
                    if !results.isEmpty {
                        resultsCard
                    }
                }
                nowPlayingCard
                hintCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .navigationTitle("音乐")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) {
            NeteaseLoginView()
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
    }

    // MARK: - 登录

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("网易云")

            if NeteaseClient.shared.isLoggedIn {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已登录")
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Button("退出") {
                        NeteaseClient.shared.signOut()
                        results = []
                        note = "已退出。"
                    }
                    .font(.aevis(13.5))
                    .foregroundStyle(.red)
                }
            } else {
                Text("还没有登录。在下面这个页面登录一次就行（扫码或手机号），凭据会自动抓过来，不用你复制。")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        showLogin = true
                    } label: {
                        Text("在 App 里登录")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Button {
                        cookieDraft = settings.neteaseCookie
                        editingCookie = true
                    } label: {
                        Text("手动贴 Cookie")
                            .font(.aevis(13.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Spacer(minLength: 0)
                }
            }

            if let note {
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("这是逆向接入，没有官方接口 —— 网易改协议就可能失效，并且存在账号被风控的风险。建议登录一个不常用的小号。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 搜索

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            label("找歌")

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
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                label("结果")
                Spacer(minLength: 8)
                Button("全部播放") {
                    Task { @MainActor in
                        await player.play(results)
                        router.showPlayer = true
                    }
                }
                .font(.aevis(13))
                .foregroundStyle(settings.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(Array(results.prefix(30).enumerated()), id: \.element.id) { index, track in
                Button {
                    // 点了直接进全屏播放器（网易云也是这个行为）——
                    // 先在后台把播放地址取回来，取到再弹，这样画面一出来就是对的封面和歌词。
                    Task { @MainActor in
                        await player.play(queue: results, index: index)
                        router.showPlayer = true
                    }
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 正在播放

    private var nowPlayingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                label("正在播放")
                Spacer(minLength: 8)
                if player.current != nil {
                    Button("全屏播放界面") { router.showPlayer = true }
                        .font(.aevis(13))
                        .foregroundStyle(settings.accentColor)
                }
            }

            if let track = player.current {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.aevis(16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track.display)
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: {
                                // ⚠️ 进度条的值必须落在 0…1 里，而且不能是 NaN。
                                // AVPlayer 在某些时刻会给 NaN，NaN 传进 SwiftUI 就是崩溃。
                                guard player.duration > 0, player.progress.isFinite else { return 0 }
                                return min(max(player.progress / player.duration, 0), 1)
                            },
                            set: { player.seek(to: min(max($0, 0), 1)) }
                        ),
                        in: 0...1
                    )
                    HStack {
                        Text(Self.time(player.progress))
                        Spacer()
                        Text(Self.time(player.duration))
                    }
                    .font(.aevisMono(11))
                    .foregroundStyle(.tertiary)
                }

                if let line = player.currentLyricLine {
                    Text(line)
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 18) {
                    controlButton("backward.fill") { Task { await player.previous() } }
                    controlButton(player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    controlButton("forward.fill") { Task { await player.next() } }
                    Spacer(minLength: 0)
                    Button("停止") { player.stop() }
                        .font(.aevis(13))
                        .foregroundStyle(.red)
                }
            } else {
                Text("还没在放。搜一首，或者让我帮你放。")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
            }

            if let error = player.errorText {
                Text(error)
                    .font(.aevis(12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var hintCard: some View {
        Text("锁屏和通知中心里也能控制播放。她也能用这些 —— 你说「放首歌」，她真的会去放，不是只回你一句「好的」。")
            .font(.aevis(11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aevisGlass(cornerRadius: 20)
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .aevisGlass(cornerRadius: 22)
    }

    // MARK: - 动作

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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
