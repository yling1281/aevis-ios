import SwiftUI

/// 数字滚动动效（第 3 轮）：值变化时逐位滚动 + spring 淡入，稳定自包含。
///
/// 用途：主页用量大百分比、墨点余额、商城档位价格、支付成功到账数字。
/// 实现要点：
/// - 内部 `@State displayed` 保存当前显示值，`onChange(of: value)` 里用 spring 动画更新；
/// - `.contentTransition(.numericText(value:))` 让位数/数值变化时按位滚动（iOS 16+）；
/// - 视图身份保持稳定（不用 `.id`），否则数字滚动会被视图重建打断。
///   调用方直接改 `value` 即可，无需自己包 `withAnimation`。
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
        // suffix 单独拼接，不能塞进 format 串（百分号会被当格式说明符）
        Text(String(format: specifier, displayed) + suffix)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText(value: displayed))
            .onChange(of: value) { _, newValue in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                    displayed = newValue
                }
            }
    }
}
