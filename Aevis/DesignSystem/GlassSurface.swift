import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 玻璃表面。**要不要玻璃由用户决定** —— 关掉就变成纯色卡片。
/// 全 App 的卡片都走这一个入口，所以一个开关就能全局生效。
extension View {
    @ViewBuilder
    func aevisGlass(cornerRadius: CGFloat = 22) -> some View {
        if AppSettings.shared.useGlass {
            if #available(iOS 26.0, *) {
                self.glassEffect(
                    .regular,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                self
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            }
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
                colors: [settings.accentColor.opacity(scheme == .dark ? 0.42 : 0.26), .clear],
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

    /// 背景图上压一层遮罩，保证文字看得清。
    /// **强度交给用户控制**（backgroundDim），默认很轻 ——
    /// 之前写死 0.30 / 0.46，用户反馈「换自定义图之后背景整个暗下来，很别扭」。
    private var scrimBackground: some View {
        Color.black.opacity(scrimOpacity)
    }

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

/// TA 的头像。
/// 用户上传了图片就用图片；没有就退回「主题色 / seed 决定的一团光」。
struct AevisAvatar: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var personaStore = PersonaStore.shared

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

    var body: some View {
        #if canImport(UIKit)
        if let image = personaStore.avatarImage {
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
                        colors: [
                            seed == 0 ? settings.accentColor : Color(hue: hue, saturation: 0.60, brightness: 0.99),
                            seed == 0
                                ? settings.accentColor.opacity(0.62)
                                : Color(hue: hue - 0.16, saturation: 0.62, brightness: 0.78)
                        ],
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
