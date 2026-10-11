import SwiftUI

/// 码支付后台的五个页签：总览 / 订单 / 通道 / 财务 / 更多。
///
/// 跟素材后台一样**只放 5 个** —— iOS 的 TabView 超过 5 个会自己冒出一个英文的
/// 「More」页签，跟整个 App 的中文界面不搭。剩下的（回调、账号、密钥、设置、
/// 轮询池、工单）全收在「更多」那一页里，用的是 `NavigationStack` 下钻。
struct PayTabs: View {
    @State private var tab = AppConfig.demoInitialTab

    var body: some View {
        TabView(selection: $tab) {
            PayOverviewView()
                .tabItem { Label("总览", systemImage: "speedometer") }
                .tag(0)
            PayOrdersView()
                .tabItem { Label("订单", systemImage: "list.bullet.rectangle") }
                .tag(1)
            PayChannelsView()
                .tabItem { Label("通道", systemImage: "arrow.triangle.branch") }
                .tag(2)
            PayFinanceView()
                .tabItem { Label("财务", systemImage: "chart.bar.fill") }
                .tag(3)
            PayMoreView()
                .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                .tag(4)
        }
    }
}
