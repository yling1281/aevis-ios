import SwiftUI

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

    @State private var tab: MainTab = .contacts

    var body: some View {
        TabView(selection: $tab) {
            ChatListView()
                .tabItem { Label(MainTab.chats.title, systemImage: MainTab.chats.symbol) }
                .tag(MainTab.chats)

            ContactsView()
                .tabItem { Label(MainTab.contacts.title, systemImage: MainTab.contacts.symbol) }
                .tag(MainTab.contacts)

            DiscoverView()
                .tabItem { Label(MainTab.discover.title, systemImage: MainTab.discover.symbol) }
                .tag(MainTab.discover)

            MeView()
                .tabItem { Label(MainTab.me.title, systemImage: MainTab.me.symbol) }
                .tag(MainTab.me)
        }
        // 这几个面板提到根上，二级页面和根视图都能触发（截图自检也靠它）
        .sheet(isPresented: $router.showSettings) {
            SettingsView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
        .sheet(isPresented: $router.showMoments) {
            MomentsView()
                .environmentObject(personaStore)
        }
        .sheet(isPresented: $router.showTogether) {
            TogetherView()
                .environmentObject(personaStore)
        }
        .fullScreenCover(isPresented: $router.showCall) {
            CallView()
                .environmentObject(personaStore)
        }
        .onAppear(perform: applyLaunchOptions)
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
        #endif
    }
}
