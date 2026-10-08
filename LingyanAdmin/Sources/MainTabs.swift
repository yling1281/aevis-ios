import SwiftUI

/// 五个页签：总览 / 订单 / 设备 / 卡密 / 账号。
///
/// 剩下的三页（审计日志 / 对外 API / 设置）做成「总览」右上角那个菜单里的**整屏页面** ——
/// iOS 的 TabView 超过 5 个会自己冒出一个英文的「More」页签，跟整个 App 的中文界面不搭，
/// 所以宁可自己收进菜单里。
struct MainTabs: View {
    @State private var tab = AppConfig.demoInitialTab

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("总览", systemImage: "chart.bar.doc.horizontal") }
                .tag(0)
            OrdersView()
                .tabItem { Label("订单", systemImage: "yensign.circle") }
                .tag(1)
            DevicesView()
                .tabItem { Label("设备", systemImage: "desktopcomputer") }
                .tag(2)
            CardsView()
                .tabItem { Label("卡密", systemImage: "creditcard") }
                .tag(3)
            UsersView()
                .tabItem { Label("账号", systemImage: "person.2") }
                .tag(4)
        }
    }
}
