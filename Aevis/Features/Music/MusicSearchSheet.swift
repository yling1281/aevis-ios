import SwiftUI

/// 找歌面板 —— **可复用的那一份**。
///
/// ## 为什么要把它抽出来（2026-10-01）
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

    /// 选了一首之后干什么。
    ///
    /// 传 nil = 用默认行为（真的去放，然后把这个面板收起来）。
    /// 之所以留这个口子：以后「一起听」想换成"只加入队列不立刻切歌"就在这儿改。
    var onPick: ((_ queue: [MusicTrack], _ index: Int) -> Void)?

    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [MusicTrack] = []
    @State private var searching = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if NeteaseClient.shared.isLoggedIn {
                        searchCard
                        if !results.isEmpty {
                            resultsCard
                        }
                    } else {
                        needLoginCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("找歌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
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

    // MARK: - 结果

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("结果")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("全部播放") {
                    pick(results, 0)
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
            ForEach(Array(results.prefix(30).enumerated()), id: \.offset) { index, track in
                Button {
                    pick(results, index)
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
}
