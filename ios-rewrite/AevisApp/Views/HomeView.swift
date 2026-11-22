import SwiftUI

/// 主页（第 1 轮骨架，仿安卓 ShaChang）：用量额度卡 + 服务九宫格 + 发现九宫格。
/// 整体可滚动（主页允许滚，登录页才禁止）；底部留 TabBar 高度 padding。
/// 卡片全部磨砂（复用 GlassComponents），九宫格用彩色圆角图标底（按用户截图）。
/// 未实现的入口统一 `showTip("「X」即将上线")` —— 绝不假装能进。
struct HomeView: View {
    /// 商城入口回调：由 MainTabView 注入以全屏拉起 ShopView；单独预览时为 nil 用内部占位。
    var onShop: (() -> Void)? = nil
    @State private var showShop = false        // 仅在 onShop == nil 时用的占位
    @State private var tip = ""
    @State private var serviceExpanded = true
    @State private var discoverExpanded = true

    /// 示例用量（第 1 轮先用展示值；后续接 balance/wallet API）。
    /// usedPercent 用 @State 从 0 起、onAppear 置目标值，触发 AnimatedNumber 的开屏滚动。
    @State private var usedPercent = 0
    private let points = 4600

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                greeting
                usageCard
                sectionHeader("服务", expanded: $serviceExpanded)
                if serviceExpanded { serviceGrid }
                sectionHeader("发现", expanded: $discoverExpanded)
                if discoverExpanded { discoverGrid }
                if !tip.isEmpty { tipBanner }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            // 底部留 TabBar 高度 + 安全区
            .padding(.bottom, 96)
        }
        .background(AppBackground())
        .onAppear {
            // 开屏让百分比从 0 滚到目标值（数字动效）
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) {
                usedPercent = 92
            }
        }
        .sheet(isPresented: $showShop) {
            // 第 2 轮接 ShopView；这轮先明确提示，不假装能进
            VStack(spacing: 14) {
                Image(systemName: "bag").font(.system(size: 34)).foregroundStyle(AE.accent)
                Text("商城即将上线").font(.system(size: 18, weight: .semibold))
                Text("第 2 轮接入五大分区").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                Button("知道了") { showShop = false }.foregroundStyle(AE.accent)
            }
            .padding(30)
            .presentationDetents([.medium])
        }
    }

    // MARK: - 顶部问候

    private var greeting: some View {
        HStack(spacing: 10) {
            AevisMascot(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("你好呀").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                Text("今天想聊点什么？")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AE.textPrimary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 用量额度卡

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用量额度")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                Spacer()
                // 两个小胶囊
                HStack(spacing: 6) {
                    capsule("用量提升")
                    capsule("按次计费")
                }
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                        AnimatedNumber(
                            value: usedPercent, suffix: "%",
                            font: .system(size: 34, weight: .bold, design: .rounded),
                            color: AE.textPrimary
                        )
                        Text("已用")
                            .font(.system(size: 12))
                            .foregroundStyle(AE.textSecondary)
                    }
                    Text("墨点 \(points) · 约 \(points / 35) 次对话")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 0)
            }

            // 进度条 + 狗头贴末端
            ZStack(alignment: .leading) {
                Capsule().fill(AE.textPrimary.opacity(0.08)).frame(height: 8)
                GeometryReader { geo in
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Color.hex(0xFFD66B), AE.brandPurple],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, geo.size.width * CGFloat(usedPercent) / 100), height: 8)
                        .overlay(alignment: .trailing) {
                            AevisMascot(size: 26)
                                .offset(x: 13, y: -11)
                                .shadow(color: AE.shadowColor, radius: 4, y: 2)
                        }
                }
                .frame(height: 8)
            }

            Text("您大约还有 \(100 - usedPercent)% 消息额度 · 12月01日 重置")
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)
        }
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
    }

    private func capsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AE.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(AE.accentSoft, in: Capsule())
    }

    // MARK: - 分区标题（可折叠）

    private func sectionHeader(_ title: String, expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 九宫格

    private struct HomeEntry: Identifiable {
        let id = UUID()
        let label: String
        let symbol: String
        let color: Color
        let badge: String = ""
    }

    private let serviceItems: [HomeEntry] = [
        HomeEntry(label: "商城", symbol: "bag.fill", color: Color.hex(0xE8913F)),
        HomeEntry(label: "装扮", symbol: "paintbrush.fill", color: Color.hex(0x9B8AF0)),
        HomeEntry(label: "日志", symbol: "book.closed.fill", color: Color.hex(0x4A90D9)),
        HomeEntry(label: "表情包", symbol: "face.smiling.fill", color: Color.hex(0xE87FA6)),
        HomeEntry(label: "工具", symbol: "wrench.fill", color: Color.hex(0x8A93A3)),
        HomeEntry(label: "会员", symbol: "crown.fill", color: Color.hex(0xE5484D)),
        HomeEntry(label: "导入DeepSeek", symbol: "key.fill", color: Color.hex(0x2E86AB)),
    ]

    private let discoverItems: [HomeEntry] = [
        HomeEntry(label: "论坛", symbol: "bubble.left.and.bubble.right.fill", color: Color.hex(0x5B8DEF)),
        HomeEntry(label: "活动", symbol: "gift.fill", color: Color.hex(0xF0A63F)),
        HomeEntry(label: "广场", symbol: "square.grid.2x2.fill", color: Color.hex(0x7B8CF0)),
        HomeEntry(label: "签到", symbol: "calendar.badge.checkmark", color: Color.hex(0x4AB85C)),
        HomeEntry(label: "加入群聊", symbol: "person.3.fill", color: Color.hex(0x9B8AF0)),
    ]

    private var serviceGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
            ForEach(serviceItems) { item in
                gridCell(item)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    private var discoverGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
            ForEach(discoverItems) { item in
                gridCell(item)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    private func gridCell(_ item: HomeEntry) -> some View {
        Button {
            if item.label == "商城" || item.label == "会员" {
                if let onShop { onShop() } else { showShop = true }
            } else {
                showTip("「\(item.label)」即将上线")
            }
        } label: {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(item.color.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: item.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(item.color)
                }
                Text(item.label)
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(AevisPressStyle(scale: 0.94))
        .accessibilityLabel(item.label)
    }

    private var tipBanner: some View {
        Text(tip)
            .font(.system(size: 12))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .transition(.opacity)
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
