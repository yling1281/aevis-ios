import SwiftUI

/// 主界面 TabBar（3 tab：主页 / 聊天 / 设置）。
///
/// Dock 完全用苹果原生的，不自己画：
/// - iOS 26+：系统自动给 Liquid Glass 玻璃 Dock；
/// - iOS 16–18：标准 tab bar（`.tint` 跟随品牌墨靛蓝）。
///
/// 背景只在**这一层**挂一次（`AppBackground()` 放在 ZStack 最底层）：
/// 以前各 tab 页各挂一份，切 tab / 关 sheet / 回前台时会有一块重绘空窗（用户看到「背景没了/闪白」）。
/// 现在 TabView 叠在同一个背景上，各 tab 页内部**不再铺不透明底色**。
/// 16–18 还要把 tab bar 自带的系统不透明底去掉，否则底部会是一条盖住背景的灰白色；
/// iOS 26 的玻璃 Dock 是系统视觉，不动它。
///
/// 二级页面收起 Dock：由被 push 的目的页自己声明 `.toolbar(.hidden, for: .tabBar)`
/// （聊天详情在 `ChatView` 里声明）。在外层加会把列表根页的 Dock 一起藏掉。
/// 商城走 `fullScreenCover`，本来就整屏盖住 Dock。
struct MainTabView: View {
    @EnvironmentObject private var session: Session

    @State private var selected = 0
    @State private var showShop = false
    /// 商城初始 tab：主页「按次计费」进来时直接落到按次 tab（index 2）
    @State private var shopInitialTab = 0
    /// 会员独立页（2026-11-23 拆页）：与商城各自一张 fullScreenCover，返回层级不串。
    @State private var showMember = false
    /// 广场（2.8）：改成从右往左滑出的**全屏二级菜单**，不用上下滑 sheet。
    /// 用同层 ZStack 覆盖，连底部 Dock 一起盖住；转场统一走 AEMotion.pageTransition。
    @State private var showPlaza = false
    @State private var plazaTab = 0

    var body: some View {
        ZStack {
        // 背景已上移到 `AevisApp.root` 的 `AppBackgroundHost`（2026-11-25）：
        // 全 App 只有一份背景，登录页 / 全屏页也统一。这里不再自铺，避免同一张图解码两次。
        TabView(selection: $selected) {
            HomeView(
                onShop: { shopInitialTab = 0; showShop = true },
                onMember: { showMember = true },
                onBuyQuota: { showMember = true },  // 「用量提升」→ 套餐页 MemberView
                onPerUse: { shopInitialTab = 2; showShop = true },  // 「按次计费」→ 商城按次 tab
                onPlaza: { tab in
                    plazaTab = tab
                    withAnimation(AEMotion.pageAnimation) { showPlaza = true }
                }
            )
                .modifier(ClearTabBarBackground())
                .tabItem { Label("主页", systemImage: "house.fill") }
                .tag(0)

            ChatListView()
                .modifier(ClearTabBarBackground())
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(1)

            SettingsView()
                .modifier(ClearTabBarBackground())
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(AE.accent)   // 选中项跟随品牌墨靛蓝（深色模式自动提亮，不用固定 accentDeep）
        .fullScreenCover(isPresented: $showShop) { ShopView(initialTab: shopInitialTab) }
        .fullScreenCover(isPresented: $showMember) { MemberView() }

        if showPlaza {
            PlazaView(initialTab: plazaTab, onClose: {
                withAnimation(AEMotion.pageAnimation) { showPlaza = false }
            })
            .environmentObject(session)
            .transition(AEMotion.pageTransition)
            .zIndex(1)
        }
        }
        .animation(AEMotion.pageAnimation, value: showPlaza)
    }
}

/// Dock 背景（2026-11-24 修「底部框怪怪的」）：iOS 16–18 原来把 tab bar 背景强行
/// `.hidden`，自定义背景从底下透上来但系统分隔线/边框还在，看起来像一条突兀的框。
/// 改成原生 `Material.regular` 磨砂底：明暗自动适配、边框自然消失，与全局
/// `AppBackground()` 同一质感；iOS 26+ 保留系统 Liquid Glass Dock 不动。
private struct ClearTabBarBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbarBackground(Material.regular, for: .tabBar)
        }
    }
}
