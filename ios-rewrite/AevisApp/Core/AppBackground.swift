import SwiftUI

/// 可自定义背景（第 1 轮：组件 + 预设，设置入口第 3 轮接）。
///
/// 由 `@AppStorage("aevisBgStyle")` 选预设（默认奶油 / 柔紫 / 海盐 / 深空），
/// `@AppStorage("aevisBgBlur")` 调整体模糊半径。用渐变 + 顶部柔光铺最底层
/// `ignoresSafeArea()`，让磨砂卡片之间透出底层背景、形成层次。
///
/// 用法：在需要背景的视图最外层 `.background(AppBackground())`。
struct AppBackground: View {
    @AppStorage("aevisBgStyle") private var style: Int = 0
    @AppStorage("aevisBgBlur") private var blurAmount: Double = 0
    @Environment(\.colorScheme) private var scheme

    private enum Preset: Int, CaseIterable {
        case cream = 0, lilac, seaSalt, deepSpace

        /// 按深浅模式返回渐变色组。
        func colors(dark: Bool) -> [Color] {
            switch (self, dark) {
            case (.cream, false):     return [Color.hex(0xFFF8EC), Color.hex(0xFFF1DC)]
            case (.cream, true):      return [Color.hex(0x1E1B24), Color.hex(0x272230)]
            case (.lilac, false):     return [Color.hex(0xF3EEFF), Color.hex(0xE7DEFF)]
            case (.lilac, true):      return [Color.hex(0x241E33), Color.hex(0x2E2642)]
            case (.seaSalt, false):   return [Color.hex(0xEAF4F4), Color.hex(0xDCEDEF)]
            case (.seaSalt, true):    return [Color.hex(0x18282B), Color.hex(0x1F3236)]
            case (.deepSpace, false): return [Color.hex(0xD9DCE6), Color.hex(0xC2C7D4)]
            case (.deepSpace, true):  return [Color.hex(0x101218), Color.hex(0x191C26)]
            }
        }
    }

    var body: some View {
        let preset = Preset(rawValue: style) ?? .cream
        ZStack(alignment: .top) {
            LinearGradient(
                colors: preset.colors(dark: scheme == .dark),
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // 顶部一点柔光，层次靠材质不靠边框
            RadialGradient(
                gradient: Gradient(colors: [AE.brandLilac.opacity(0.35), Color.clear]),
                center: .top, startRadius: 0, endRadius: 320
            )
            .frame(height: 360)
        }
        .blur(radius: CGFloat(blurAmount))
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
