import SwiftUI

/// 发现 —— 微信的第三个 tab。
///
/// 朋友圈、一起听这些原来藏在「更多」面板里的东西，
/// 现在集中摆在这儿（用户的要求：跟微信一样）。
///
/// ⭐ 2026-10-04：老板看完电脑版新界面之后说「**手机端也同步这些**」——
///    这一页一次补齐了四块：虚拟银行 / 日记 / 待办 / 一起玩。
struct DiscoverView: View {
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var player = MusicPlayer.shared
    @ObservedObject private var couple = CoupleStore.shared
    @ObservedObject private var diary = DiaryStore.shared
    @ObservedObject private var todo = TodoStore.shared
    /// 选人：这些入口以前直接吃"当前活跃角色"，现在统一先选（默认上次那个）。
    ///
    /// ⚠️ 2026-11-12:这里原来还有一行 `@EnvironmentObject private var personaStore`,
    ///    和下面这个同名的 `@ObservedObject` 撞了 ——
    ///    `invalid redeclaration of 'personaStore'`，CI 编译直接失败。
    ///    保留 ObservedObject（指向单例），不依赖环境注入，sheet 里也能用。
    @ObservedObject private var personaStore = PersonaStore.shared

    /// 所有二级页共用一个 sheet 通道。
    ///
    /// 以前这一页挂了 **9 个** `.sheet` 在同一个 View 上（music / couple /
    /// diary / todo / browser / appleMusic / shop / publish / picker）。
    /// SwiftUI 一个视图只能可靠承载一个 sheet，多挂之后点「商城」根本
    /// 没反应 —— 用户 2026-11-13：「人设广场点不进去」。现在全收进这个 enum。
    @State private var sheet: DiscoverSheet?

    enum DiscoverSheet: Identifiable {
        case picker(DiscoverPick)
        case music, couple, diary, todo, browser, appleMusic, shop, publish

        var id: String {
            switch self {
            case .picker(let k): return "pick-" + k.rawValue
            case .music: return "music"
            case .couple: return "couple"
            case .diary: return "diary"
            case .todo: return "todo"
            case .browser: return "browser"
            case .appleMusic: return "apple-music"
            case .shop: return "shop"
            case .publish: return "publish"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                V2TopBar(title: "发现", subtitle: "广场、朋友圈、音乐")
                ScrollView {
                    VStack(spacing: 14) {
                        // 人设广场：发现页第一屏就能横着刷。
                        // 2026-11-13 用户：「发现页的话就是你全部重组」
                        //                  「直接弄一个商城，里面是人设和表情包还有音色，
                        //                    然后那个表情包直接去掉」——
                        // 原来的「人设广场横滑条」换成一张商城入口卡。
                        ShopEntryCard { sheet = .shop }

                        // 2026-11-13 用户：「首先人设广场，你有两个，撞了两个设字」——
                        // 横滑条上已经有「人设广场 / 写一个 / 全部」，这块再摆一个
                        // 「刷一刷 + 全部人设 + 写一个人设」就是同一件事说两遍，
                        // 而且两个「设」字挨着看着像标题重复。整块去掉。

                        VStack(spacing: 8) {
                            V2SectionTitle("一起玩")
                            V2Card {
                                V2Row(symbol: "photo.on.rectangle.angled",
                                      title: "朋友圈",
                                      detail: momentsLine,
                                      action: { ask(.moment) })
                                V2Divider()
                                // ⭐ 2026-10-01 新加。用户点名要过（2026-09-27 就答应了），
                                //    跟钱包 / 音乐不一样 —— **不挂内测开关**，
                                //    这是他明确要的产品功能，不是试验品。
                                V2Row(symbol: "heart.text.square",
                                      title: "情侣空间",
                                      detail: coupleLine,
                                      action: { ask(.couple) })
                                V2Divider()
                                V2Row(symbol: "book.closed",
                                      title: "日记",
                                      detail: diaryLine,
                                      action: { ask(.diary) })
                                V2Divider()
                                V2Row(symbol: "checklist",
                                      title: "一起做的事",
                                      detail: todoLine,
                                      action: { ask(.todo) })
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
                                      action: { ask(.music) })
                                V2Divider()
                                V2Row(symbol: "music.note.house",
                                      title: "苹果音乐",
                                      detail: "用系统 MusicKit 搜歌、播放（需 Apple Music 订阅）",
                                      action: { ask(.music) })
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
                                      action: { sheet = .browser })
                                V2Divider()
                                // 实时通话：和上面那两块用的是同一个 `Experimental.enabled`
                                //（现在恒为 true），所以它一直都在。用户 2026-10-01 要
                                //「让他真的能动起来」→ 这一条也从「更多」面板里提出来了，
                                // 现在发现页、聊天页右上角、陪伴卡三处都能直接开。
                                V2Row(symbol: "phone.arrow.up.right",
                                      title: "实时通话",
                                      detail: "你说话，\(Pronoun.current)听；\(Pronoun.current)回话，用语音念出来",
                                      action: { ask(.call) })
                            }
                        }
                    }
                    .padding(.horizontal, V2.gutter)
                    .padding(.bottom, 18)
                }
            }
            .v2Page()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sheet) { s in
                switch s {
                case .picker(let kind):
                    PersonaPicker(title: kind.title, showsCurrent: false) { id in
                        PersonaMemory.shared.remember([id], for: kind.feature)
                        run(kind, ids: [id])
                    }

                case .music:
                    // MusicView 自带工具栏但**没有返回键**，这里补一颗。
                    NavigationStack {
                        MusicView()
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("关闭") { sheet = nil }
                                }
                            }
                    }

                case .couple:
                    // CoupleSpaceView 自带 NavigationStack + 「关闭」。
                    CoupleSpaceView()

                case .diary:
                    DiaryView()

                case .todo:
                    TodoView()

                case .browser:
                    // InAppBrowserView 的标题栏只在导航壳里成立，而且它自己
                    // **没有任何关闭按钮** —— 必须在这里补，否则出不去。
                    NavigationStack {
                        InAppBrowserView(start: nil, title: "浏览器")
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("关闭") { sheet = nil }
                                }
                            }
                    }

                case .appleMusic:
                    // 苹果音乐：原来既没标题也没关闭，只能下滑退出 —— 补上返回。
                    // 模拟器不支持 MusicKit，只能真机。
                    NavigationStack {
                        AppleMusicView()
                            .navigationTitle("苹果音乐")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("关闭") { sheet = nil }
                                }
                            }
                    }

                case .shop:
                    ShopView()

                case .publish:
                    PersonaPublishView { _ in }
                }
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
        if args.contains("-aevisOpenDiary") { sheet = .diary }
        if args.contains("-aevisOpenTodo") { sheet = .todo }
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

    // MARK: - 选人（2026-11-12）

    /// 这些入口以前一点就直接进，默认"当前活跃角色"。现在先问一句跟谁，
    /// 默认值是**上次选的那个人**（`PersonaMemory`），只有一个人时不打扰。
    enum DiscoverPick: String, Identifiable {
        case moment, couple, diary, todo, call, music

        var id: String { rawValue }

        var feature: String {
            switch self {
            case .moment: return PersonaMemory.Feature.moment
            case .couple: return PersonaMemory.Feature.couple
            case .diary: return PersonaMemory.Feature.together
            case .todo: return PersonaMemory.Feature.together
            case .call: return PersonaMemory.Feature.call
            case .music: return PersonaMemory.Feature.listen
            }
        }

        var title: String {
            switch self {
            case .moment: return "和谁一起看"
            case .couple: return "和谁的情侣空间"
            case .diary: return "和谁的日记"
            case .todo: return "和谁一起做"
            case .call: return "打给谁"
            case .music: return "和谁一起听"
            }
        }
    }

    private func ask(_ kind: DiscoverPick) {
        let alive = personaStore.contacts
        if alive.isEmpty { return }
        // 只有一个联系人：别每次都弹一层，直接走
        if alive.count == 1 {
            run(kind, ids: [alive[0].id])
            return
        }
        sheet = .picker(kind)
    }

    private func run(_ kind: DiscoverPick, ids: Set<UUID>) {
        guard let id = ids.first else { return }
        // 这一批服务（通话 / 一起听 / 情侣空间 / 日记 / 一起做）目前都是
        // "跟着当前活跃角色走"的单例状态；先切过去再执行，等于把这些功能
        // 绑到用户刚选的那个人身上。
        if personaStore.active?.id != id { personaStore.select(id) }

        switch kind {
        case .moment: router.showMoments = true
        case .couple: sheet = .couple
        case .diary: sheet = .diary
        case .todo: sheet = .todo
        case .call: router.startCall()
        case .music: sheet = .music
        }
    }

}
