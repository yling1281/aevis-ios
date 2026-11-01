import SwiftUI

/// 发现 —— 微信的第三个 tab。
///
/// 朋友圈、一起听这些原来藏在「更多」面板里的东西，
/// 现在集中摆在这儿（用户的要求：跟微信一样）。
///
/// ⭐ 2026-10-04：老板看完电脑版新界面之后说「**手机端也同步这些**」——
///    这一页一次补齐了四块：虚拟银行 / 日记 / 待办 / 一起玩。
struct DiscoverView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var couple = CoupleStore.shared
    @ObservedObject private var diary = DiaryStore.shared
    @ObservedObject private var todo = TodoStore.shared

    @State private var showMusic = false
    @State private var showCouple = false
    @State private var showDiary = false
    @State private var showTodo = false
    @State private var showMC = false
    @State private var showBrowser = false
    @State private var showAppleMusic = false
    /// 人设广场（2026-11-01 用户要求：在发现页就能刷，也能自己写一个上传）。
    @State private var showPlaza = false
    @State private var showPublishPersona = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                V2TopBar(title: "发现", subtitle: "广场、朋友圈、音乐")
                ScrollView {
                    VStack(spacing: 14) {
                        // 人设广场：发现页第一屏就能横着刷。
                        // 用户 2026-11-01：「人社广场你要在发现页那里做一个人可以在那里刷，
                        // 然后的话呢也能在那里自己写一个上传」。
                        PersonaPlazaStrip(
                            onOpenAll: { showPlaza = true },
                            onUpload: { showPublishPersona = true }
                        )

                        VStack(spacing: 8) {
                            V2SectionTitle("刷一刷", trailing: "全部人设", onTrailing: { showPlaza = true })
                            // 横滑条上面已经有「全部」了，这里不再摆一行「人设广场」——
                            // 同一屏两个一模一样的入口，用户会以为其中一个是别的功能。
                            V2Card {
                                V2Row(symbol: "square.and.pencil",
                                      title: "写一个人设传上去",
                                      detail: "自己写的也能被别人的通讯录取走",
                                      action: { showPublishPersona = true })
                            }
                        }

                        VStack(spacing: 8) {
                            V2SectionTitle("一起玩")
                            V2Card {
                                V2Row(symbol: "photo.on.rectangle.angled",
                                      title: "朋友圈",
                                      detail: momentsLine,
                                      action: { router.showMoments = true })
                                V2Divider()
                                // ⭐ 2026-10-01 新加。用户点名要过（2026-09-27 就答应了），
                                //    跟钱包 / 音乐不一样 —— **不挂内测开关**，
                                //    这是他明确要的产品功能，不是试验品。
                                V2Row(symbol: "heart.text.square",
                                      title: "情侣空间",
                                      detail: coupleLine,
                                      action: { showCouple = true })
                                V2Divider()
                                V2Row(symbol: "book.closed",
                                      title: "日记",
                                      detail: diaryLine,
                                      action: { showDiary = true })
                                V2Divider()
                                V2Row(symbol: "checklist",
                                      title: "一起做的事",
                                      detail: todoLine,
                                      action: { showTodo = true })
                            }
                        }

                        VStack(spacing: 8) {
                            V2SectionTitle("听点东西")
                            V2Card {
                                // ⭐ 2026-10-31 用户要求：音乐与「一起听」合并成「网易云音乐」。
                                //
                                // 🔴 2026-10-31 晚修正：之前这里直接 `router.showPlayer = true`
                                //    —— 打开的是**全屏播放器**，用户点进去看到的还是"以前那个播放器"，
                                //    新做的「推荐 / 排行榜 / 我的」三页根本没机会出现。
                                //    用户反馈「网易云音乐还是以前那样子的」就是这个原因。
                                //
                                //    现在开 **MusicView**（三 Tab）。播放器从底下那条播放条进 ——
                                //    点歌只开始播，点播放条才进全屏，这才是网易云的手感。
                                V2Row(symbol: "music.note",
                                      title: "网易云音乐",
                                      detail: musicLine,
                                      action: { showMusic = true })
                                V2Divider()
                                V2Row(symbol: "music.note.house",
                                      title: "苹果音乐",
                                      detail: "用系统 MusicKit 搜歌、播放（需 Apple Music 订阅）",
                                      action: { showAppleMusic = true })
                            }
                        }

                        VStack(spacing: 8) {
                            V2SectionTitle("其它")
                            V2Card {
                                // ⭐ 2026-10-06：内置浏览器 —— 页内能上网，看到好的点右上角
                                //    「纸飞机」就发给 ta。入口放在发现页第一张卡。
                                V2Row(symbol: "safari",
                                      title: "浏览器",
                                      detail: "打开网页，看到好的就发给\(Pronoun.current)",
                                      action: { showBrowser = true })
                                V2Divider()
                                // 实时通话：和上面那两块用的是同一个 `Experimental.enabled`
                                //（现在恒为 true），所以它一直都在。用户 2026-10-01 要
                                //「让他真的能动起来」→ 这一条也从「更多」面板里提出来了，
                                // 现在发现页、聊天页右上角、陪伴卡三处都能直接开。
                                V2Row(symbol: "phone.arrow.up.right",
                                      title: "实时通话",
                                      detail: "你说话，\(Pronoun.current)听；\(Pronoun.current)回话，用语音念出来",
                                      action: { router.startCall() })
                            }
                        }
                    }
                    .padding(.horizontal, V2.gutter)
                    .padding(.bottom, 18)
                }
            }
            .v2Page()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showMusic) {
                // MusicView 自己没有导航壳，这里给它一个
                NavigationStack { MusicView() }
            }
            .sheet(isPresented: $showCouple) {
                // CoupleSpaceView 自带 NavigationStack。
                CoupleSpaceView()
            }
            .sheet(isPresented: $showDiary) {
                DiaryView()
            }
            .sheet(isPresented: $showTodo) {
                TodoView()
            }
            .sheet(isPresented: $showMC) {
                MCView()
            }
            .sheet(isPresented: $showBrowser) {
                // 内置浏览器。它自己的标题栏 / 返回键**只在被导航壳包住时才成立**
                //（`InAppBrowserView` 里用的是 `.navigationTitle` / `.navigationBarTitleDisplayMode`），
                // 所以这里必须给它一个 NavigationStack —— 同上面 MusicView 那一条。
                //
                // ⚠️ 它自己**没有任何关闭按钮**（原来只在被 push 时靠系统返回键）。
                //    放进 sheet 后，没有这一颗「关闭」老板就永远退不出去 —— 必须在导航栏补。
                NavigationStack {
                    InAppBrowserView(start: nil, title: "浏览器")
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showBrowser = false }
                            }
                        }
                }
            }
            // 苹果音乐（Apple Music / MusicKit）。⚠️ 模拟器不支持 MusicKit，只能真机。
            .sheet(isPresented: $showAppleMusic) {
                AppleMusicView()
            }
            .sheet(isPresented: $showPlaza) {
                PersonaPlazaView()
            }
            .sheet(isPresented: $showPublishPersona) {
                PersonaPublishView { _ in }
            }
            .onAppear {
                applyLaunchOptions()
            }
        }
    }

    /// 截图自检用的启动直达（只在 Debug 生效）。
    private func applyLaunchOptions() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-aevisOpenDiary") { showDiary = true }
        if args.contains("-aevisOpenTodo") { showTodo = true }
        if args.contains("-aevisOpenMC") { showMC = true }
        #endif
    }

    // MARK: - 文案

    private var momentsLine: String {
        let count = MomentStore.shared.moments.count
        return count == 0 ? "还没人发过动态" : "\(count) 条动态"
    }

    private var togetherLine: String {
        together.active ? "进行中 · \(together.currentTrackTitle)" : "两个人同步听同一首歌"
    }

    /// 人设广场那一行：有多少个可刷的。
    private var plazaLine: String {
        let n = PersonaPlazaStore.shared.rows.count
        return n == 0 ? "别人写的人设，也能传自己的" : "\(n) 个人设可以刷"
    }

    private var musicLine: String {
        player.current?.display ?? "搜歌、放歌，让 ta 跟着一起听"
    }

    private var coupleLine: String {
        if let days = couple.daysTogether { return "在一起第 \(days) 天" }
        if let next = couple.upcoming.first { return "\(next.title) · \(next.daysText())" }
        return "倒数日、在一起多少天"
    }

    private var diaryLine: String {
        let count = diary.sorted.count
        return count == 0 ? "两个人写同一个本子" : "已经写了 \(count) 篇"
    }

    private var todoLine: String {
        if todo.items.isEmpty { return "想一起做的事，都写在这儿" }
        if todo.openCount == 0 { return "清单上这些都做完啦" }
        return "还有 \(todo.openCount) 件等着一起做"
    }

    // MARK: - 零件
    //
    // 2026-11-01：原来那一对 `card` / `entry` 已经删了 —— 现在整页改用 v2 的
    // `V2Card` + `V2Row`（圆 22、细边、圆形淡底图标），再留一份就是两套长相。
}
