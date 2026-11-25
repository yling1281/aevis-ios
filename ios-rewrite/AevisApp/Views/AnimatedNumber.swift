import SwiftUI

/// 数字滚动动效：值变化时**逐帧插值**滚动（不是瞬间跳变）。
///
/// 用途：主页用量大百分比、墨点余额、商城档位价格、支付成功到账数字。
///
/// 2026-11-25 重写的原因：之前只是把 `@State displayed` 放进 `withAnimation` 更新，
/// 但 `Text` 的内容是 `String(format:)` 算出来的，SwiftUI **不会对字符串插值** ——
/// 动画期间一个中间值都看不到，最后"bang"一下跳到终值，用户说的"数字瞬间变"就是这个。
///
/// 现在的做法：`InterpolatingText` 自己实现 `Animatable`，把 `value` 暴露成 `animatableData`。
/// SwiftUI 会在动画每一帧把插值后的 value 塞回来重新求 body，文字是**真的一帧帧滚动**的。
/// 这条路径在 iOS 16 上就能用，不依赖 `.contentTransition`（那是 iOS 17+）。
///
/// iOS 17+ 再叠一层 `.contentTransition(.numericText())`，让位数变化时按位滚动，更好看。
///
/// 支持 Int / Double（价格用两位小数 specifier）。示例：
///   AnimatedNumber(value: 92)                       // 92
///   AnimatedNumber(value: 15.0, specifier: "%.2f")  // 15.00
struct AnimatedNumber: View {
    let value: Double
    var specifier: String = "%.0f"
    var font: Font = .system(size: 16, weight: .bold, design: .rounded)
    var color: Color = AE.textPrimary
    var suffix: String = ""

    @State private var displayed: Double

    /// 整数便利构造（最常用）。
    init(
        value: Int,
        font: Font = .system(size: 16, weight: .bold, design: .rounded),
        color: Color = AE.textPrimary,
        suffix: String = ""
    ) {
        self.value = Double(value)
        // 内部一律按 Double 格式化：%d 配 Double 会输出乱码，用 %.0f 显示整数
        self.specifier = "%.0f"
        self.font = font
        self.color = color
        self.suffix = suffix
        self._displayed = State(initialValue: Double(value))
    }

    /// 浮点构造（价格等需要两位小数）。
    init(
        value: Double,
        specifier: String = "%.2f",
        font: Font = .system(size: 16, weight: .bold, design: .rounded),
        color: Color = AE.textPrimary,
        suffix: String = ""
    ) {
        self.value = value
        self.specifier = specifier
        self.font = font
        self.color = color
        self.suffix = suffix
        self._displayed = State(initialValue: value)
    }

    var body: some View {
        InterpolatingText(
            value: displayed,
            specifier: specifier,
            font: font,
            color: color,
            suffix: suffix
        )
        // 视图身份保持稳定（不用 .id），否则滚动会被视图重建打断
        .modifier(NumericRollEffect(value: displayed))
        // 单参数 onChange 是 iOS 14+；双参数版本要 iOS 17，部署目标 16.0 用不了
        .onChange(of: value) { newValue in
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                displayed = newValue
            }
        }
    }
}

/// 会随动画逐帧重算文本的数字视图。
///
/// `animatableData` 暴露 `value` 是关键：SwiftUI 在动画期间反复把插值写进 value 并重算 body，
/// 于是 Text 的内容每一帧都在变 —— 这才是"滚动"。用 `Text` 直接渲染 `@State` 做不到这一点。
private struct InterpolatingText: View, Animatable {
    var value: Double
    let specifier: String
    let font: Font
    let color: Color
    let suffix: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        // suffix 单独拼接，不能塞进 format 串（百分号会被当格式说明符）
        Text(String(format: specifier, value) + suffix)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

/// `.contentTransition(.numericText(value:))` 是 iOS 17+；低版本什么都不加
/// （数值照样逐帧滚动，由 `InterpolatingText` 负责，只是没有"按位翻牌"那层）。
private struct NumericRollEffect: ViewModifier {
    let value: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.contentTransition(.numericText(value: value))
        } else {
            content
        }
    }
}
