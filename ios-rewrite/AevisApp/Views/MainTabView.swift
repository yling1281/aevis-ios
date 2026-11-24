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
    @State private var selected = 0
    @State private var showShop = false
    /// 会员独立页（2026-11-23 拆页）：与商城各自一张 fullScreenCover，返回层级不串。
    @State private var showMember = false

    var body: some View {
        ZStack {
            // 唯一的一份背景：所有 tab 共用，切换时不会重建
            AppBackground()

            TabView(selection: $selected) {
                HomeView(onShop: { showShop = true }, onMember: { showMember = true })
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
        }
        .fullScreenCover(isPresented: $showShop) { ShopView() }
        .fullScreenCover(isPresented: $showMember) { MemberView() }
    }
}

/// 让 tab bar 背景透明（iOS 16.0 可用的 `toolbarBackground`），使 `MainTabView` 底层的
/// `AppBackground()` 一直透上来；iOS 26+ 保留系统 Liquid Glass 玻璃 Dock，不做任何处理。
private struct ClearTabBarBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.toolbarBackground(.hidden, for: .tabBar)
        }
    }
}
