import SwiftUI

/// 发现 —— 微信的第三个 tab。
///
/// 朋友圈、一起听这些原来藏在「更多」面板里的东西，
/// 现在集中摆在这儿（用户的要求：跟微信一样）。
struct DiscoverView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var player = MusicPlayer.shared

    @State private var showMusic = false
    @State private var showDouyin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    card {
                        entry("朋友圈", "photo.on.rectangle.angled", momentsLine) {
                            router.showMoments = true
                        }
                        entry("一起听", "music.note.list", togetherLine) {
                            router.showTogether = true
                        }
                        entry("音乐", "music.note", musicLine) {
                            showMusic = true
                        }
                    }
                    card {
                        entry("抖音", "play.rectangle", "打开抖音、点赞、评论、解析分享链接") {
                            showDouyin = true
                        }
                        entry("实时通话", "phone.arrow.up.right", "你说话，\(Pronoun.current)听；\(Pronoun.current)回话，用语音念出来") {
                            router.showCall = true
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationTitle("发现")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showMusic) {
                // MusicView 自己没有导航壳，这里给它一个
                NavigationStack { MusicView() }
            }
            .sheet(isPresented: $showDouyin) {
                DouyinBrowserView()
            }
        }
    }

    // MARK: - 文案

    private var momentsLine: String {
        let count = MomentStore.shared.moments.count
        return count == 0 ? "还没人发过动态" : "\(count) 条动态"
    }

    private var togetherLine: String {
        together.active ? "进行中 · \(together.currentTrackTitle)" : "两个人同步听同一首歌"
    }

    private var musicLine: String {
        player.current?.display ?? "搜歌、放歌，让她跟着一起听"
    }

    // MARK: - 零件

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func entry(
        _ title: String,
        _ symbol: String,
        _ detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(AppSettings.shared.accentColor)
                    .frame(width: 34, height: 34)
                    .aevisGlass(cornerRadius: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
