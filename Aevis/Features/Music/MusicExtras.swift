import SwiftUI

#if canImport(AVKit)
import AVKit
#endif

/// 播放器底部「评论」那一格打开的东西。
///
/// 数据是**这首歌在网易云的真实评论**（`NeteaseClient.comments`：
/// `hotComments` 在前、`comments` 在后）。不是占位文案 ——
/// 2026-10-31 之前这里是一个 `say("评论功能还没接上")`，用户点名要接。
struct MusicCommentsSheet: View {
    let songID: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [NeteaseClient.NeteaseComment] = []
    @State private var loading = true
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("正在拿评论…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText {
                    emptyState(icon: "exclamationmark.bubble",
                               text: errorText,
                               retry: true)
                } else if comments.isEmpty {
                    emptyState(icon: "bubble.left",
                               text: "这首歌还没有人评论",
                               retry: false)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(comments) { comment in
                                row(comment)
                                Divider().padding(.leading, 56)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(title.isEmpty ? "评论" : "评论 · \(title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func row(_ c: NeteaseClient.NeteaseComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: c.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(c.nickname)
                        .font(.aevis(13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if c.isHot {
                        // 「热门」这个小标是网易云自己的做法（它标的是"精彩评论"）。
                        Text("热门")
                            .font(.aevis(9.5, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }

                    Spacer(minLength: 0)

                    if c.likedCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "heart")
                            Text("\(c.likedCount)")
                        }
                        .font(.aevis(10.5))
                        .foregroundStyle(.tertiary)
                    }
                }

                Text(c.content)
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if !c.timeText.isEmpty {
                    Text(c.timeText)
                        .font(.aevis(10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func emptyState(icon: String, text: String, retry: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.aevis(30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.aevis(14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if retry {
                Button("重试") { Task { await load(force: true) } }
                    .font(.aevis(14, weight: .medium))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(force: Bool = false) async {
        guard force || comments.isEmpty else { return }
        loading = true
        errorText = nil
        do {
            let list = try await NeteaseClient.shared.comments(songID: songID)
            comments = list
        } catch {
            errorText = "拿不到评论：\(error.localizedDescription)"
        }
        loading = false
    }
}

/// 「视频」那一格打开的东西：这首歌的 MV。
///
/// 地址由 `NeteaseClient.mvURL` 现拿（`/api/song/enhance/play/mv/url`），
/// 播放交给系统的 `VideoPlayer` —— 不自己写播放器，省得再管一遍缓冲和全屏。
struct MVPlayerSheet: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(AVKit)
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                        .onAppear { player.play() }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                #else
                Text("这台设备不支持视频播放")
                    .font(.aevis(14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        #if canImport(AVKit)
                        player?.pause()
                        #endif
                        dismiss()
                    }
                }
            }
            .onAppear {
                #if canImport(AVKit)
                if player == nil { player = AVPlayer(url: url) }
                #endif
            }
            .onDisappear {
                #if canImport(AVKit)
                // MV 放着的时候退出去不暂停，声音会跟着飘到别的页面 —— 必须收。
                player?.pause()
                #endif
            }
        }
    }
}
