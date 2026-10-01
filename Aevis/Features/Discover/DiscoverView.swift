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
    @ObservedObject private var couple = CoupleStore.shared

    @State private var showMusic = false
    @State private var showDouyin = false
    @State private var showCouple = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    card {
                        entry("朋友圈", "photo.on.rectangle.angled", momentsLine) {
                            router.showMoments = true
                        }
                        // ⭐ 2026-10-01 新加。用户点名要过（2026-09-27 就答应了），
                        //    跟钱包 / 音乐不一样 —— **不挂内测开关**，
                        //    这是他明确要的产品功能，不是试验品。
                        entry("情侣空间", "heart.text.square", coupleLine) {
                            showCouple = true
                        }
                        // 一起听 / 音乐 默认藏起来（见 Experimental）：买家装上去
                        // 只会看到"要登录网易云、要订阅 Apple Music"，属于劝退项。
                        if Experimental.enabled {
                            // ⚠️ 「一起听」现在**直接开全屏播放器**（2026-10-01）。
                            // 以前它开的是 `TogetherView`（三张设置卡片），
                            // 用户说「不好用」「里面的东西全部重来」——
                            // 那个面板已删，形态选择和找歌都搬进 `PlayerView` 了。
                            entry("一起听", "music.note.list", togetherLine) {
                                router.showPlayer = true
                            }
                            entry("音乐", "music.note", musicLine) {
                                showMusic = true
                            }
                        }
                    }
                    // ⚠️ 抖音**永远不显示**（用户 2026-09-28：「抖音关掉」）。
                    //    抖音的代码没删：哪天想放开，把那段 entry 加回来即可。
                    //
                    // 实时通话：和上面那两块用的是同一个 `Experimental.enabled`
                    //（现在恒为 true），所以它一直都在。用户 2026-10-01 要
                    //「让他真的能动起来」→ 这一条也从「更多」面板里提出来了，
                    // 现在发现页、聊天页右上角、陪伴卡三处都能直接开。
                    card {
                        entry("实时通话", "phone.arrow.up.right", "你说话，\(Pronoun.current)听；\(Pronoun.current)回话，用语音念出来") {
                            router.startCall()
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
            .sheet(isPresented: $showCouple) {
                // CoupleSpaceView 自带 NavigationStack。
                CoupleSpaceView()
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

    private var coupleLine: String {
        if let days = couple.daysTogether { return "在一起第 \(days) 天" }
        if let next = couple.upcoming.first { return "\(next.title) · \(next.daysText())" }
        return "倒数日、在一起多少天"
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
