import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 玻璃表面。**要不要玻璃由用户决定** —— 关掉就变成纯色卡片。
/// 全 App 的卡片都走这一个入口，所以一个开关就能全局生效。
extension View {
    @ViewBuilder
    func aevisGlass(cornerRadius: CGFloat = 22) -> some View {
        // 圆角跟着用户的设置走
        let radius = cornerRadius * CGFloat(AppSettings.shared.cornerScale)

        if AppSettings.shared.useGlass, #available(iOS 26.0, *) {
            // 清透用 .clear，标准/磨砂用 .regular（磨砂靠材质近似，效果更实）
            self.glassEffect(
                AppSettings.shared.glassStyle == .clear ? .clear : .regular,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
        } else if AppSettings.shared.useGlass {
            // iOS 26 以下：按材质档位近似
            self
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(AppSettings.shared.glassStyle == .clear
                              ? AnyShapeStyle(.ultraThinMaterial)
                              : AnyShapeStyle(.regularMaterial))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
        }
    }
}

/// 底部／顶部的横向长条。比玻璃实，避免内容从底下透上来 —— 用户要的「留白」。
struct AevisBarBackground: View {
    var body: some View {
        Rectangle()
            .fill(.bar)
    }
}

/// 聊天背景。默认给一个「光晕」，但用户能换成纯色、纸感或自己的图片。
struct AevisBackground: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            switch settings.backgroundStyle {
            case .aurora:
                aurora
            case .plain:
                base
            case .paper:
                paper
            case .custom:
                customImage
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 各样样式

    private var base: Color {
        scheme == .dark
            ? Color(red: 0.05, green: 0.05, blue: 0.08)
            : Color(red: 0.96, green: 0.96, blue: 0.98)
    }

    /// 两团光晕，第一团跟着主题色走，所以换主题色连背景都会变。
    private var aurora: some View {
        ZStack {
            base
            RadialGradient(
                colors: [
                    settings.accentColor.opacity(
                        (scheme == .dark ? 0.42 : 0.26) * settings.tintStrength
                    ),
                    .clear
                ],
                center: UnitPoint(x: 0.14, y: 0.04),
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color(red: 0.18, green: 0.76, blue: 0.72).opacity(scheme == .dark ? 0.30 : 0.20), .clear],
                center: UnitPoint(x: 0.92, y: 0.10),
                startRadius: 0,
                endRadius: 400
            )
        }
    }

    /// 暖白／暖灰，看久了眼睛不累。
    private var paper: some View {
        ZStack {
            scheme == .dark
                ? Color(red: 0.10, green: 0.095, blue: 0.09)
                : Color(red: 0.965, green: 0.95, blue: 0.925)
            RadialGradient(
                colors: [Color(red: 0.85, green: 0.74, blue: 0.58).opacity(scheme == .dark ? 0.10 : 0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 520
            )
        }
    }

    @ViewBuilder
    private var customImage: some View {
        #if canImport(UIKit)
        if let data = settings.customBackgroundData, let image = UIImage(data: data) {
            // 关键：用 Color.clear 定尺寸、图片放 overlay。
            // 直接把 scaledToFill 放进 ZStack 会把整棵布局撑大，
            // 底部的输入栏会被挤出屏幕 —— 之前就是这个 bug。
            Color.clear
                .overlay(
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                )
                .clipped()
                .overlay(scrimBackground)
        } else {
            aurora
        }
        #else
        aurora
        #endif
    }

    /// 背景图上压一层遮罩。不留这一层的话，白字压在花哨的图上根本看不清。
    private var scrimBackground: some View {
        Color.black.opacity(scrimOpacity)
    }

    /// 背景图上压一层遮罩，保证文字看得清。
    /// **强度交给用户控制**（backgroundDim），默认很轻 ——
    /// 之前写死 0.30 / 0.46，用户反馈「换自定义图之后背景整个暗下来，很别扭」。
    private var scrimOpacity: Double {
        let extra = min(max(settings.backgroundDim, 0), 0.8)
        return scheme == .dark ? 0.08 + extra : 0.04 + extra
    }
}

/// TA 的雏形：一团会呼吸的光。跟随主题色。
struct AevisOrb: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            settings.accentColor.opacity(0.95),
                            settings.accentColor.opacity(0.55)
                        ],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 4,
                        endRadius: 136
                    )
                )
                .frame(width: 134, height: 134)
                .blur(radius: 1.5)
                .scaleEffect(breathing ? 1.06 : 0.96)
                .opacity(breathing ? 1.0 : 0.86)

            Circle()
                .strokeBorder(Color.primary.opacity(0.28), lineWidth: 0.8)
                .frame(width: 172, height: 172)
                .scaleEffect(breathing ? 1.10 : 0.94)
                .opacity(breathing ? 0.18 : 0.52)
        }
        .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }
}

/// 气泡本体。**聊天里的气泡和设置里的预览共用这一个** ——
/// 保证「预览看到的」就是「聊天里得到的」，不会两边长得不一样。
struct AevisBubble: View {
    var text: String
    var look: BubbleLook
    var color: Color
    var corner: CGFloat
    var fontSize: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    /// 玻璃 / 描边样式下用的字色，也就是用户在「文字颜色」里挑的那个。
    var plainTextColor: Color

    /// 订阅表情包 —— 导入自定义表情后，气泡里的预览要立刻跟着变。
    @ObservedObject private var emoji = EmojiPack.shared

    /// 真正显示出来的字。
    /// `[微笑]` 这类文字表情会被换成真正的表情符号，
    /// 不认得的方括号内容原样留着（正常打字写到方括号时不该被动）。
    private var displayText: String {
        text.isEmpty ? "…" : emoji.render(text)
    }

    /// 按背景亮度决定字色 —— 不然浅色气泡上写白字会看不见。
    private var onColorText: Color {
        #if canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
           (0.299 * red + 0.587 * green + 0.114 * blue) > 0.66 {
            return Color(red: 0.09, green: 0.09, blue: 0.11)
        }
        #endif
        return Color.white
    }

    private var textColor: Color {
        switch look.style {
        case .solid, .gradient: return onColorText
        case .glass, .outline: return plainTextColor
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    private var label: some View {
        Text(displayText)
            .font(.aevis(fontSize))
            .foregroundStyle(textColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
    }

    var body: some View {
        styled
    }

    @ViewBuilder
    private var styled: some View {
        switch look.style {
        case .solid:
            label.background(shape.fill(color))
        case .gradient:
            label.background(
                shape.fill(
                    LinearGradient(
                        colors: [color, color.opacity(0.62)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
        case .glass:
            label
                .background(shape.fill(color.opacity(0.18)))
                .aevisGlass(cornerRadius: corner)
        case .outline:
            label
                .background(shape.fill(color.opacity(0.07)))
                .overlay(shape.strokeBorder(color.opacity(0.85), lineWidth: 1.4))
        }
    }
}

/// TA 的头像，或者「我」的头像。
/// 用户上传了图片就用图片；没有就退回「主题色 / seed 决定的一团光」。
struct AevisAvatar: View {
    /// 这个头像是谁的。两侧都能自定义（用户要求）。
    enum Source {
        case ai
        case me
    }

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var profileStore = ProfileStore.shared

    var source: Source = .ai
    var size: CGFloat = 32
    var seed: Int = 0

    /// 备选颜色必须在色环上拉开距离。
    /// 之前用 `0.70 + seed * 0.055` 算，六个全挤在紫→粉这一小段里，
    /// 视觉上根本分不出来（截图自检时发现的）。
    /// seed 0 留给主题色，其余五个是紫 / 青 / 绿 / 橙 / 玫红 / 蓝紫。
    private static let seedHues: [Double] = [0.72, 0.55, 0.38, 0.09, 0.92, 0.68]

    private var hue: Double {
        let index = abs(seed) % Self.seedHues.count
        return Self.seedHues[index]
    }

    private var uploadedImage: UIImage? {
        switch source {
        case .ai: return personaStore.avatarImage
        case .me: return profileStore.avatarImage
        }
    }

    /// 没上传照片时的兜底颜色。我的固定用一个青色，和 TA 区分开。
    private var fallbackTop: Color {
        switch source {
        case .ai:
            return seed == 0
                ? settings.accentColor
                : Color(hue: hue, saturation: 0.60, brightness: 0.99)
        case .me:
            return Color(hue: 0.52, saturation: 0.42, brightness: 0.92)
        }
    }

    private var fallbackBottom: Color {
        switch source {
        case .ai:
            return seed == 0
                ? settings.accentColor.opacity(0.62)
                : Color(hue: hue - 0.16, saturation: 0.62, brightness: 0.78)
        case .me:
            return Color(hue: 0.48, saturation: 0.44, brightness: 0.72)
        }
    }

    var body: some View {
        #if canImport(UIKit)
        if let image = uploadedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.6))
        } else {
            orb
        }
        #else
        orb
        #endif
    }

    private var orb: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [fallbackTop, fallbackBottom],
                        center: UnitPoint(x: 0.34, y: 0.28),
                        startRadius: 1,
                        endRadius: size * 0.78
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.30), lineWidth: 0.6)
        }
        .frame(width: size, height: size)
    }
}
