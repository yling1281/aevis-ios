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
    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var diary = DiaryStore.shared
    @ObservedObject private var todo = TodoStore.shared
    @ObservedObject private var herPhone = HerPhoneStore.shared

    @State private var showMusic = false
    @State private var showCouple = false
    @State private var showWallet = false
    @State private var showDiary = false
    @State private var showTodo = false
    @State private var showMC = false
    @State private var showRealLife = false
    @State private var showHerPhone = false
    @State private var showBrowser = false

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
                        // 一起听 / 音乐：**已经放开了**（2026-10-04）。
                        // 原来它们裹在 `Experimental.enabled` 里（虽然那个开关恒为 true）。
                        // 现在跟「情侣空间」一样是**裸入口** —— 这块功能已经定下来，
                        // 不该再挂在"内测"的名头后面。
                        //
                        // ⚠️ 「一起听」开的是**全屏播放器**（2026-10-01）：
                        //    以前它开 `TogetherView`（三张设置卡片），用户说「不好用」，
                        //    那个面板已删，形态选择和找歌都搬进 `PlayerView` 了。
                        entry("一起听", "music.note.list", togetherLine) {
                            router.showPlayer = true
                        }
                        entry("音乐", "music.note", musicLine) {
                            showMusic = true
                        }
                        // ⭐ 一起玩《我的世界》（2026-10-04 从电脑版同步过来）。
                        entry("一起玩", "gamecontroller", "选个人设，陪你在《我的世界》里过一天") {
                            showMC = true
                        }
                        // ⭐ 2026-10-06：内置浏览器 —— 页内能上网，看到好的点右上角
                        //    「纸飞机」就发给 ta。入口放在发现页第一张卡。
                        entry("浏览器", "safari", "打开网页，看到好的就发给\(Pronoun.current)") {
                            showBrowser = true
                        }
                    }
                    card {
                        // ⭐ 2026-10-04：虚拟银行搬进发现页（以前只藏在聊天页加号里），
                        //    并且跟聊天记录一起进网盘备份。
                        entry("虚拟银行", "yensign.circle", walletLine) {
                            showWallet = true
                        }
                        entry("日记", "book.closed", diaryLine) {
                            showDiary = true
                        }
                        entry("一起做的事", "checklist", todoLine) {
                            showTodo = true
                        }
                        // ⭐ 2026-10-06：真实生活（逛店 / 点外卖）。这一页的物流进度
                        //    是**跟着时钟自己往前走**的，停在那儿就能看见它推进。
                        entry("真实生活", "takeoutbag.and.cup.and.straw", realLifeLine) {
                            showRealLife = true
                        }
                        // ⭐ 2026-10-06：ta 的小手机 —— 看 ta 装了哪些 App、刚才在干什么。
                        entry("ta 的小手机", "iphone.gen3", herPhoneLine) {
                            showHerPhone = true
                        }
                    }
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
            .sheet(isPresented: $showWallet) {
                WalletView()
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
            .sheet(isPresented: $showRealLife) {
                // RealLifeView 自带 `.aevisScreen("真实生活")`（返回 + 关闭），
                // 这里**别再套 NavigationStack**（套了会多一层壳）。
                RealLifeView()
            }
            .sheet(isPresented: $showHerPhone) {
                // HerPhoneView 自带 NavigationStack + 「关闭」，同样**别再套**。
                HerPhoneView()
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
            .onAppear {
                applyLaunchOptions()
            }
        }
    }

    /// 截图自检用的启动直达（只在 Debug 生效）。
    private func applyLaunchOptions() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-aevisOpenWallet") { showWallet = true }
        if args.contains("-aevisOpenDiary") { showDiary = true }
        if args.contains("-aevisOpenTodo") { showTodo = true }
        if args.contains("-aevisOpenMC") { showMC = true }
        if args.contains("-aevisOpenRealLife") { showRealLife = true }
        if args.contains("-aevisOpenHerPhone") { showHerPhone = true }
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

    private var musicLine: String {
        player.current?.display ?? "搜歌、放歌，让 ta 跟着一起听"
    }

    private var coupleLine: String {
        if let days = couple.daysTogether { return "在一起第 \(days) 天" }
        if let next = couple.upcoming.first { return "\(next.title) · \(next.daysText())" }
        return "倒数日、在一起多少天"
    }

    private var walletLine: String {
        "我钱包里还有 " + WalletStore.money(wallet.myBalance)
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

    private var realLifeLine: String {
        "点外卖、买东西，进度跟着时钟走"
    }

    private var herPhoneLine: String {
        let count = herPhone.apps.count
        return count == 0 ? "看 ta 的手机装了啥、刚才在干什么" : "看 ta 的手机，已经装了 \(count) 个 App"
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
