import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 底下那四个 tab。
///
/// 用户的要求：「进去是联系人，底下有聊天、通讯录、发现、我」。
/// 所以整个 App 从「一进去就是一对一聊天」改成了
/// 「先进通讯录 / 会话，点某个人再进聊天」—— 跟微信一样。
enum MainTab: String, CaseIterable, Identifiable {
    case chats
    case contacts
    case discover
    case me

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "聊天"
        case .contacts: return "通讯录"
        case .discover: return "发现"
        case .me: return "我"
        }
    }

    var symbol: String {
        switch self {
        case .chats: return "message"
        case .contacts: return "person.2"
        case .discover: return "safari"
        case .me: return "person.crop.circle"
        }
    }

    /// 设置里存的是 rawValue（字符串）—— 认不出来就回「通讯录」，
    /// 不会因为改过枚举名而崩。
    static func named(_ raw: String) -> MainTab {
        MainTab(rawValue: raw) ?? .contacts
    }
}

struct MainTabView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chat: ChatStore

    @ObservedObject private var router = AppRouter.shared
    /// 她主动提的申请（打电话 / 看屏幕 / 一起听）—— 你要点一下才会真的开始。
    @ObservedObject private var companionRequest = CompanionRequest.shared

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var tab: MainTab = .contacts

    var body: some View {
        Group {
            if usesSplitLayout {
                splitLayout
            } else {
                phoneTabs
            }
        }
        // 这几个面板提到根上，二级页面和根视图都能触发（截图自检也靠它）
        .sheet(isPresented: $router.showSettings, onDismiss: { router.settingsFocus = nil }) {
            // `focus` 只为一件事存在：她申请看屏幕、你点了同意之后，
            // 要直接落到「陪伴」那张卡（系统的录屏按钮只在那儿）。
            SettingsView(focus: router.settingsFocus)
                .aevisScreen("设置")
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
        // ⚠️ 朋友圈**特意不用 fullScreenCover**。
        // 用户要的是微信那种「从右边滑进来的一整页」，而 fullScreenCover 的转场
        // 是固定的"从下往上弹"，SwiftUI 改不了方向。所以这里自己做一层 overlay
        // 配 `.move(edge: .trailing)`，关闭由 MomentsView 的 onClose 回调触发
        // （自定义呈现下 `@Environment(\.dismiss)` 是失效的）。
        .sheet(isPresented: $router.showTogether) {
            TogetherView()
                .aevisScreen("一起听")
                .environmentObject(personaStore)
        }
        .fullScreenCover(isPresented: $router.showCall) {
            CallView()
                .aevisScreen("通话")
                .environmentObject(personaStore)
        }
        // 全屏播放器（仿网易云那个）。点一首歌就弹它。
        .fullScreenCover(isPresented: $router.showPlayer) {
            PlayerView()
                .aevisScreen("播放器")
        }
        // 朋友圈：右滑进、右滑出（微信的手感）。放在 overlay 里，
        // 所以它盖在 tab 栏之上，是一整页。
        .overlay {
            if router.showMoments {
                MomentsView(onClose: { router.showMoments = false })
                    .aevisScreen("朋友圈")
                    .environmentObject(personaStore)
                    .transition(.move(edge: .trailing))
                    .zIndex(30)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: router.showMoments)
        // 底栏切换也记一笔（用户点名要的：「我切换了聊天、切换了发现、切换了我的」）。
        .onChange(of: tab) { _, now in
            BlackBox.tap("底栏 · \(now.title)")
        }
        // 她主动提的申请 —— 从顶上滑进来一条，但**不挡你手上的事**
        //（不点它照样能继续打字、翻朋友圈）。
        .overlay(alignment: .top) {
            if let request = companionRequest.pending {
                CompanionRequestBar(
                    item: request,
                    onAccept: { accept(request.kind) },
                    onDecline: { companionRequest.decline() }
                )
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .animation(.easeOut(duration: 0.26), value: companionRequest.pending)
        .onAppear(perform: applyLaunchOptions)
        .onAppear {
            // 录屏的进度要**全程**刷新，不能只在设置页里刷。
            // 早先只有 `CompanionCard` 在轮询：用户在聊天界面眼巴巴等着她
            // 「看到屏幕」，界面却永远停在进设置那一刻的样子，
            // 于是反馈就变成了「录屏还是不行」。
            ScreenCompanion.shared.startPolling()
        }
    }

    // MARK: - 两种布局（iPhone 底栏 / iPad 分栏）
    //
    // 2026-09-28 用户要求：「iPad 上现在只是 iPhone 布局拉伸」→ 做真布局。
    //
    // 做法是**只换外层容器，页面本身一个字不动** ——
    // 四个页面各自都带着自己的 `NavigationStack`，塞进分栏的详情区正好，
    // 再包一层反而会变成嵌套导航（push 两次、返回按钮叠两层）。

    /// 要不要用 iPad 那种「左边一列、右边内容」的布局。
    ///
    /// ⚠️ `idiom == .pad` **和** size class 是 regular，**两个都要**：
    /// - 只看 size class 的话，**iPhone 横屏也是 regular**（Plus / Max 那几款），
    ///   手机会莫名其妙变成 iPad 布局；
    /// - 只看 idiom 的话，iPad 分屏到很窄（Slide Over）也硬要分栏，
    ///   左边那一列挤掉小半个屏，右边内容窄得没法看。
    private var usesSplitLayout: Bool {
        guard sizeClass == .regular else { return false }
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    /// iPhone：底下那四个 tab（原样）。
    private var phoneTabs: some View {
        TabView(selection: $tab) {
            // ⚠️ `page(for:)` 里那四行 `.aevisScreen` 是**全量操作埋点**的一半，
            // 别删 —— 底栏四个页面 + 那几个弹层全是从这一处呈现的，
            // 挂在那里 = 一种布局改完两种布局都覆盖
            //（用户要求「不管点了哪个按键都要记起来」）。
            page(for: .chats)
                .tabItem { Label(MainTab.chats.title, systemImage: MainTab.chats.symbol) }
                .tag(MainTab.chats)

            page(for: .contacts)
                .tabItem { Label(MainTab.contacts.title, systemImage: MainTab.contacts.symbol) }
                .tag(MainTab.contacts)

            page(for: .discover)
                .tabItem { Label(MainTab.discover.title, systemImage: MainTab.discover.symbol) }
                .tag(MainTab.discover)

            page(for: .me)
                .tabItem { Label(MainTab.me.title, systemImage: MainTab.me.symbol) }
                .tag(MainTab.me)
        }
    }

    /// iPad：左边一列导航、右边是选中的那一页。
    ///
    /// ⚠️ 侧边栏的选中态要**接回 `tab`**（而不是自己另存一份）——
    /// 这样「设置里选了默认进哪一页」「`-aevisOpenTab=` 截图参数」
    /// 和底栏那套逻辑是**同一份状态**，两边不会各说各话。
    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: padSelection) {
                Section {
                    ForEach(MainTab.allCases) { item in
                        Label(item.title, systemImage: item.symbol)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Aevis")
            .navigationBarTitleDisplayMode(.inline)
        } detail: {
            page(for: tab)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 右栏当前显示哪一页。
    ///
    /// ⚠️ `List(selection:)` 只吃**可选**绑定（没选中时是 nil），
    /// 所以这里做一层桥接：往 `tab` 写的时候把 nil 挡掉，
    /// 免得点空白处把当前页清没了。
    private var padSelection: Binding<MainTab?> {
        Binding(get: { tab },
                set: { if let picked = $0 { tab = picked } })
    }

    /// 四个主页面。**两种布局共用** —— 埋点只写一遍。
    @ViewBuilder
    private func page(for item: MainTab) -> some View {
        switch item {
        case .chats:
            ChatListView().aevisScreen("聊天列表")
        case .contacts:
            ContactsView().aevisScreen("通讯录")
        case .discover:
            DiscoverView().aevisScreen("发现")
        case .me:
            MeView().aevisScreen("我")
        }
    }

    /// 她申请的事你点了同意 —— 到这里才真的去执行。
    ///
    /// ⚠️ 「看屏幕」只能把你**送到陪伴卡前面**，不能替你开始录屏 ——
    /// iOS 规定录屏必须用户本人点系统那个按钮（状态栏要亮红点，得让你知情）。
    /// 这是能做到的极限，申请条上也照实写了。
    private func accept(_ kind: CompanionRequest.Kind) {
        switch kind {
        case .call:
            router.showCall = true
        case .listenTogether:
            router.showTogether = true
        case .screenShare:
            router.settingsFocus = "companion"
            router.showSettings = true
        }
    }

    /// 进哪个 tab 是**用户设的**（出厂状态是「通讯录」）。
    /// 截图自检可以用 `-aevisOpenTab=xxx` 指定。
    private func applyLaunchOptions() {
        tab = MainTab.named(settings.defaultTab)

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let prefix = "-aevisOpenTab="
        for argument in args where argument.hasPrefix(prefix) {
            tab = MainTab.named(String(argument.dropFirst(prefix.count)))
        }
        // 截图自检要在**启动时**就看到这些面板 —— 聊天页这时还没出现，
        // 所以从根上弹（这几个开关以前挂在聊天页里，搬家了）。
        if args.contains("-aevisOpenSettings") { router.showSettings = true }
        if args.contains("-aevisOpenMoments") { router.showMoments = true }
        if args.contains("-aevisOpenTogether") { router.showTogether = true }
        if args.contains("-aevisOpenPlayer") { router.showPlayer = true }
        #endif
    }
}
