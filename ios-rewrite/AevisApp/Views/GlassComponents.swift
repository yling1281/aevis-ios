import SwiftUI

// MARK: - 磨砂玻璃通用组件
//
// 2026-11-24：用户希望更新弹窗（及未来的支付半弹窗）统一做成「磨砂玻璃」质感。
// 这里把玻璃材质收敛成可复用组件：层次靠材质与透明度区分，不靠边框。
// 需要看到背后内容透出的场景，外层 sheet 要配 `.presentationBackground(.clear)`。

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
    var strokeOpacity: CGFloat = 0.22
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .background(shape.fill(material))                       // 毛玻璃：模糊背后内容
            .background(shape.fill(tint.opacity(tintOpacity)))       // 轻填充：统一色调
            .overlay(shape.stroke(strokeColor.opacity(strokeOpacity), lineWidth: 0.8))
            .clipShape(shape)
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
        strokeOpacity: CGFloat = 0.22
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
/// 需配合外层 `.presentationBackground(.clear)` 才能看到 presenting view 透出。
struct GlassBackdrop: View {
    var material: Material = .ultraThin

    var body: some View {
        Rectangle()
            .fill(material)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - 版本兼容

extension View {
    /// `.presentationBackground(.clear)` 是 iOS 16.4+ API，而工程部署目标是 16.0。
    /// 低版本上直接不加（sheet 会保持系统默认底色），高版本才有"透出背后模糊"的效果。
    /// 用它替换裸调用，避免 `is only available in iOS 16.4 or newer` 编译失败。
    @ViewBuilder
    func glassSheetBackground() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(.clear)
        } else {
            self
        }
    }
}
