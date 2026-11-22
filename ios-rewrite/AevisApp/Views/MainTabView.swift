import SwiftUI

/// 主界面 TabBar（5 tab：主页 / 聊天 / 动态 / 音乐 / 设置）。
///
/// 分系统：
/// - iOS 26+：系统原生 `TabView` + `.tabItem`，让系统给 Liquid Glass 玻璃 Dock（不自定义）。
/// - iOS 18/19：自定义底部 Dock —— 深藏青胶囊滑到当前项（复用 SegmentedTabs 的平移思路），
///   图标 + 文字选中变白。ZStack 覆盖在内容之上，内容区底部留 padding。
///
/// 动态 / 音乐 / 商城等未做的入口明确提示「即将上线」，不假装能进。
struct MainTabView: View {
    @State private var selected = 0
    @State private var showShop = false

    private let tabs: [(title: String, icon: String)] = [
        ("主页", "house.fill"),
        ("聊天", "bubble.left.and.bubble.right.fill"),
        ("动态", "bolt.fill"),
        ("音乐", "music.note"),
        ("设置", "gearshape.fill"),
    ]

    var body: some View {
        if #available(iOS 26, *) {
            // iOS 26+：系统原生 TabView，Liquid Glass Dock 由系统提供
            TabView(selection: $selected) {
                tabContent(0).tabItem { Label(tabs[0].title, systemImage: tabs[0].icon) }.tag(0)
                tabContent(1).tabItem { Label(tabs[1].title, systemImage: tabs[1].icon) }.tag(1)
                tabContent(2).tabItem { Label(tabs[2].title, systemImage: tabs[2].icon) }.tag(2)
                tabContent(3).tabItem { Label(tabs[3].title, systemImage: tabs[3].icon) }.tag(3)
                tabContent(4).tabItem { Label(tabs[4].title, systemImage: tabs[4].icon) }.tag(4)
            }
            .fullScreenCover(isPresented: $showShop) { ShopView() }
        } else {
            // iOS 18/19：自定义 Dock
            ZStack(alignment: .bottom) {
                tabContent(selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                customDock
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }
            .background(AppBackground())
            .fullScreenCover(isPresented: $showShop) { ShopView() }
        }
    }

    @ViewBuilder
    private func tabContent(_ index: Int) -> some View {
        switch index {
        case 0: HomeView { showShop = true }
        case 1: ChatListView()
        case 2: PlaceholderTab(title: "动态", icon: "bolt.fill")
        case 3: PlaceholderTab(title: "音乐", icon: "music.note")
        case 4: SettingsView()
        default: EmptyView()
        }
    }

    /// 自定义底部 Dock：深藏青胶囊滑到当前项 + 图标文字选中变白。
    private var customDock: some View {
        GeometryReader { geo in
            let itemW = (geo.size.width - 36) / CGFloat(tabs.count)
            ZStack(alignment: .leading) {
                // 胶囊底槽
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AE.accentSoft.opacity(0.9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(AE.textPrimary.opacity(0.06), lineWidth: 0.5)
                    }

                // 滑动的深藏青胶囊（spring 平移，squash & stretch 交给下方形变）
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(AE.accentDeep)
                    .frame(width: itemW - 6, height: 46)
                    .offset(x: 3 + itemW * CGFloat(selected))
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selected)

                // 五个图标 + 文字
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                        Button { if selected != i { selected = i } } label: {
                            VStack(spacing: 3) {
                                Image(systemName: t.icon)
                                    .font(.system(size: 18, weight: .medium))
                                Text(t.title)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(selected == i ? .white : AE.textSecondary)
                            .frame(width: itemW, height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t.title)
                    }
                }
            }
            .frame(height: 52)
            .glassCard(cornerRadius: 20, material: .regular, tintOpacity: 0.12)
        }
        .frame(height: 52)
    }
}

/// 未实现 tab 的占位页：明确「即将上线」，不假装能进。
private struct PlaceholderTab: View {
    let title: String
    let icon: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(AE.accent.opacity(0.6))
            Text("\(title)即将上线")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AE.textPrimary)
            Text("这一版先把主页和聊天做好，敬请期待")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
    }
}
