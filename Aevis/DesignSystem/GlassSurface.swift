import SwiftUI

/// 玻璃表面：iOS 26 上走系统原生液态玻璃，低版本用材质近似。
/// 全 App 的卡片都走这一个入口，以后想统一调风格只改这里。
extension View {
    @ViewBuilder
    func aevisGlass(cornerRadius: CGFloat = 22) -> some View {
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
    }
}

/// 背景：深色/浅色都成立的柔和光晕，不依赖 UIKit 颜色。
struct AevisBackground: View {
    @Environment(\.colorScheme) private var scheme

    private var base: Color {
        scheme == .dark
            ? Color(red: 0.05, green: 0.05, blue: 0.08)
            : Color(red: 0.96, green: 0.96, blue: 0.98)
    }

    var body: some View {
        ZStack {
            base
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.36, blue: 0.98).opacity(scheme == .dark ? 0.42 : 0.30), .clear],
                center: UnitPoint(x: 0.14, y: 0.04),
                startRadius: 0,
                endRadius: 430
            )
            RadialGradient(
                colors: [Color(red: 0.18, green: 0.76, blue: 0.72).opacity(scheme == .dark ? 0.34 : 0.24), .clear],
                center: UnitPoint(x: 0.92, y: 0.10),
                startRadius: 0,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
    }
}

/// 她的雏形：一团会呼吸的光。
struct AevisOrb: View {
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.58, green: 0.50, blue: 1.00),
                            Color(red: 0.28, green: 0.70, blue: 0.86)
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

/// 她的头像。目前是一团有颜色的光；avatarSeed 变了颜色就变，
/// 所以使用者换人设时头像也跟着换。以后支持上传图片后，这里会优先用图片。
struct AevisAvatar: View {
    var size: CGFloat = 32
    var seed: Int = 0

    private var hue: Double {
        0.70 + Double(abs(seed) % 6) * 0.055
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.60, brightness: 0.99),
                            Color(hue: hue - 0.16, saturation: 0.62, brightness: 0.78)
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
