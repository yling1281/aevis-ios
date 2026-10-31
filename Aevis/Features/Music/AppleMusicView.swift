import SwiftUI
import MusicKit

/// Apple Music 页：授权 → 搜歌 → 点一下用系统播放器放。
///
/// 播放走 `ApplicationMusicPlayer`（系统播放器），所以锁屏 / 控制中心 / 灵动岛
/// 那一套系统控件自动就有 —— 不用我们再造一遍。
struct AppleMusicView: View {
    @ObservedObject private var provider = AppleMusicProvider.shared

    @State private var query = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider.authStatus != .authorized {
                authCard
            } else {
                searchBar
                if searching {
                    ProgressView().padding()
                }
                resultsList
            }

            if let note {
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Apple Music 通过系统播放，需要用你自己的 Apple Music 会员。没有会员能搜不能放。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .task { provider.refreshStatus() }
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("连接 Apple Music", systemImage: "music.note")
                .font(.aevis(15, weight: .medium))
            Text("授权后就能在这里搜 Apple Music 的歌，点一下用系统播放器放。曲库和播放都来自 Apple Music。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await provider.requestAuthorization() }
            } label: {
                Text("连接 Apple Music")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜 Apple Music 的歌", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await runSearch() } }
            if !query.isEmpty {
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "arrow.right.circle.fill")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(results, id: \.id) { song in
                    Button { Task { await play(song) } } label: {
                        HStack(spacing: 12) {
                            artwork(for: song)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title)
                                    .font(.aevis(14.5))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text([song.artistName, song.albumTitle]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " · "))
                                    .font(.aevis(12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "play.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private func artwork(for song: Song) -> some View {
        Group {
            if let url = song.artwork?.url(width: 56, height: 56) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.08)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 44, height: 44)
            }
        }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searching = true
        note = nil
        do {
            results = try await provider.search(term)
            if results.isEmpty { note = "没搜到，换个词试试。" }
        } catch {
            note = "搜歌失败：\(error.localizedDescription)"
        }
        searching = false
    }

    private func play(_ song: Song) async {
        do {
            let player = ApplicationMusicPlayer.shared
            let items = MusicItemCollection([song])
            player.queue = ApplicationMusicPlayer.Queue(playing: items)
            try await player.play()
        } catch {
            note = "放不了：\(error.localizedDescription)（多半是没 Apple Music 会员）"
        }
    }
}
