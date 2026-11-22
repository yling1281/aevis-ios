import SwiftUI

/// 主界面 TabBar（3 tab：主页 / 聊天 / 设置）。
///
/// 2026-11-22 收敛：Dock 完全用苹果原生的，不再自己画任何东西。
/// - iOS 26+：系统自动给 Liquid Glass 玻璃 Dock；
/// - iOS 16–18：标准 tab bar（`.tint` 跟随品牌墨靛蓝）。
///
/// 二级页面收起 Dock：由被 push 的目的页自己声明 `.toolbar(.hidden, for: .tabBar)`
/// （iOS 16+ 可用），系统在 push 动画里把底栏一起收走（聊天详情在 `ChatView` 里声明）。
/// 在外层加是无效的：那会连列表根页的 Dock 一起藏掉。
/// 商城走 `fullScreenCover`，本来就整屏盖住 Dock，不需要额外处理。
struct MainTabView: View {
    @State private var selected = 0
    @State private var showShop = false

    var body: some View {
        TabView(selection: $selected) {
            HomeView { showShop = true }
                .tabItem { Label("主页", systemImage: "house.fill") }
                .tag(0)

            ChatListView()
                .tabItem { Label("聊天", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(1)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(AE.accent)   // 选中项跟随品牌墨靛蓝（深色模式自动提亮，不用固定 accentDeep）
        .fullScreenCover(isPresented: $showShop) { ShopView() }
    }
}
