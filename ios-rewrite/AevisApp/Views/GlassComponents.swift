import SwiftUI

// MARK: - 材质 Token（2026-11-25 按用户参考图定妆）
//
// 参考图（1206×2622 @3x ≈ 402×874pt）提炼出的材质语言：
// - **真模糊**：`Material`（`.ultraThinMaterial`）底层必须有真实背景才好看，
//   所以全 App 共用 `AppBackground` 一张图；纯 `white.opacity(x)` 假装半透明是**被打回的做法**。
// - **卡片无描边**，靠 `white.opacity(0.55~0.72)` 提亮 + 极淡阴影（黑 0.05 / r22 / y9）做分离。
// - **气泡无描边**，圆角 20，底色 `white.opacity(0.70)`。
//
// 所有数值集中在这里：以后用户再调质感，只改这个 enum，不动页面。
enum AEGlass {
    /// 卡片圆角（参考图 28pt 连续圆角）。`AE.cardRadius`（20）仍用于历史页面，互不影响。
    static let cardRadius: CGFloat = 28
    /// 卡片提亮层不透明度：浅色模式
    static let cardFillOpacity: Double = 0.62
    /// 卡片提亮层不透明度：深色模式（深色下用黑罩，避免整片发灰）
    static let cardDarkFillOpacity: Double = 0.34
    /// 卡片描边不透明度。参考图**无描边**，故为 0；
    /// 若用户回退到「要 1px 高光」，把这里改成 0.45 即可（全局生效）。
    static let strokeOpacity: Double = 0
    /// 深色模式描边（仅在 strokeOpacity > 0 时有意义）
    static let strokeDarkOpacity: Double = 0.18
    /// 阴影：几乎看不见，只做分离感
    static let shadowOpacity: Double = 0.05
    static let shadowRadius: CGFloat = 22
    static let shadowY: CGFloat = 9

    /// 气泡圆角（参考图 20pt 连续圆角）
    static let bubbleRadius: CGFloat = 20
    /// 气泡底色：浅色 / 深色
    static let bubbleFillOpacity: Double = 0.70
    static let bubbleDarkFillOpacity: Double = 0.62

    /// 背景白色蒙版：首页（照片只剩极淡纹理，整体读起来是暖白）
    static let veilHome: Double = 0.86
    /// 背景白色蒙版：聊天页（背景图看得清，文字靠气泡承载）
    static let veilChat: Double = 0.60
    /// 背景白色蒙版：其余页面取中间值
    static let veilDefault: Double = 0.74
}

// MARK: - 磨砂玻璃通用组件
//
// 2026-11-24：用户希望更新弹窗（及未来的支付半弹窗）统一做成「磨砂玻璃」质感。
// 这里把玻璃材质收敛成可复用组件：层次靠材质与透明度区分，不靠边框。
// 半屏 sheet 统一用 `.glassSheetBackground()`（原生磨砂背板，不再透明）；
// 需要更厚遮罩时在 sheet 内容里垫一层 `GlassBackdrop()`。

/// 磨砂玻璃卡片：半透明材质 + 轻填充 + 圆角，内容由调用方提供。
///
/// 用法：
/// ```swift
/// GlassCard(cornerRadius: 16) {
///     Text("更新说明").foregroundStyle(AE.accent)
/// }
/// // 或视图扩展：
/// Text("说明").glassCard()
/// ```
/// `Material`（`.ultraThin` / `.thin` / `.regular`）为 iOS 15+ API，本工程最低 iOS 16 可用；
/// 材质本身随深浅模式自适应，填充色 `tint` 默认白色并叠加低透明度。
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var material: Material = .thin
    /// 覆盖在材质上的轻填充色，用来提亮（浅色模式）或统一色调
    var tint: Color = .white
    var tintOpacity: CGFloat = 0.16
    var strokeColor: Color = .white
    /// 参考图卡片无描边 → 默认 0（`AEGlass.strokeOpacity`）。传 >0 才画。
    var strokeOpacity: CGFloat = CGFloat(AEGlass.strokeOpacity)
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .background(shape.fill(material))                       // 毛玻璃：模糊背后内容
            .background(shape.fill(tint.opacity(tintOpacity)))       // 轻填充：统一色调
            .overlay {
                if strokeOpacity > 0 {
                    shape.stroke(strokeColor.opacity(Double(strokeOpacity)), lineWidth: 1)
                }
            }
            .clipShape(shape)
            // 参考图：黑 0.05 / r22 / y9，几乎看不见，只做分离（不画框）
            .shadow(
                color: Color.black.opacity(AEGlass.shadowOpacity),
                radius: AEGlass.shadowRadius,
                x: 0,
                y: AEGlass.shadowY
            )
    }
}

/// 视图扩展：给任意视图套一层磨砂玻璃卡片，方便行内组合。
extension View {
    func glassCard(
        cornerRadius: CGFloat = 16,
        material: Material = .thin,
        tint: Color = .white,
        tintOpacity: CGFloat = 0.16,
        strokeColor: Color = .white,
        strokeOpacity: CGFloat = CGFloat(AEGlass.strokeOpacity)
    ) -> some View {
        GlassCard(
            cornerRadius: cornerRadius,
            material: material,
            tint: tint,
            tintOpacity: tintOpacity,
            strokeColor: strokeColor,
            strokeOpacity: strokeOpacity,
            content: { self }
        )
    }
}

/// 磨砂玻璃全屏背板：放在 ZStack 最底层，让其后（sheet 背后）的界面透出模糊感。
/// 2026-11-24：加一层**明暗自适应**的轻底色 —— 浅色偏白、深色偏暗，
/// 避免只有 `.ultraThin` 材质时支付半屏看着像透明浮在页面上。
struct GlassBackdrop: View {
    var material: Material = .regular

    var body: some View {
        ZStack {
            // 明色偏白、暗色偏暗；与系统材质叠加后仍是磨砂，不是纯色挡板
            Color.adaptive(
                dark: Color.hex(0x141416).opacity(0.55),
                light: Color.white.opacity(0.55)
            )
            Rectangle().fill(material)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 用量卡专用玻璃

/// 用量额度卡的玻璃材质（2026-11-25 定妆，按用户参考图二次校准）。
///
/// 用户原话：「有点透，但不是特别透」；后来又强调参考图的玻璃「**真的**是这么做的」。
/// 定妆参数（全部来自 `AEGlass`，页面别自己再写一遍）：
/// - 底：`.ultraThinMaterial`（系统真模糊，`UIVisualEffectView` 同源）—— 参考图就是这一档；
///   比 `.regularMaterial` 透，但下面还有一层提亮罩，实际观感比 `.regular` 更"玻璃"而不是更"糊"
/// - 填充：浅色 `white.opacity(0.62)` / 深色 `black.opacity(0.34)`，盖住大半细节又留通透
/// - 描边：参考图**无描边**（`AEGlass.strokeOpacity == 0`）
/// - 阴影：黑 0.05 / r22 / y9
struct UsageCardGlass: ViewModifier {
    var cornerRadius: CGFloat = AEGlass.cardRadius
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(.ultraThinMaterial))
            .background(
                shape.fill(
                    scheme == .dark
                        ? Color.black.opacity(AEGlass.cardDarkFillOpacity)
                        : Color.white.opacity(AEGlass.cardFillOpacity)
                )
            )
            .overlay {
                if AEGlass.strokeOpacity > 0 {
                    shape.stroke(
                        Color.white.opacity(scheme == .dark ? AEGlass.strokeDarkOpacity : AEGlass.strokeOpacity),
                        lineWidth: 1
                    )
                }
            }
            .clipShape(shape)
            .shadow(
                color: Color.black.opacity(AEGlass.shadowOpacity),
                radius: AEGlass.shadowRadius,
                x: 0,
                y: AEGlass.shadowY
            )
    }
}

extension View {
    /// 用量额度卡质感：`usageCard` 用的就是这个，别在页面里再手写一遍材质。
    func usageCardGlass(cornerRadius: CGFloat = AEGlass.cardRadius) -> some View {
        modifier(UsageCardGlass(cornerRadius: cornerRadius))
    }
}

// MARK: - 版本兼容

extension View {
    /// 半屏弹窗背板（2026-11-24 修「背后透明」）：iOS 16.4+ 用系统原生材质做背景，
    /// 明色偏白、暗色偏暗且随深浅模式自动切换；不再 `.clear` 成透明。
    /// `.presentationBackground` 是 iOS 16.4+ API，16.0–16.3 保持系统默认磨砂底。
    @ViewBuilder
    func glassSheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(.regularMaterial)
        } else {
            self
        }
    }
}
