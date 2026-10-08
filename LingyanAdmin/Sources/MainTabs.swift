import SwiftUI

struct MainTabs: View {
    @State private var tab = AppConfig.demoInitialTab

    var body: some View {
        TabView(selection: $tab) {
            OverviewView()
                .tabItem { Label("概览", systemImage: "chart.bar.doc.horizontal") }
                .tag(0)
            MaterialsView()
                .tabItem { Label("素材", systemImage: "square.grid.2x2") }
                .tag(1)
            DevicesView()
                .tabItem { Label("设备", systemImage: "desktopcomputer") }
                .tag(2)
            CardsView()
                .tabItem { Label("卡密", systemImage: "creditcard") }
                .tag(3)
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .tag(4)
        }
    }
}
