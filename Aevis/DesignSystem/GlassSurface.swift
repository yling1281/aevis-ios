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
            // iOS 26 以下：没有真液态玻璃，就用「加厚毛玻璃」近似 ——
            // 材质底 + 顶部内高光 + 双色描边（顶亮底暗）＋ 柔光外阴影，
            // 让它在纯色底上也看得出「玻璃的厚度」，而不是一块死板的色块。
            // （老板反馈：iOS 18 上「像玻璃但底是纯色、透不出东西」。）
            let material: AnyShapeStyle = AppSettings.shared.glassStyle == .clear
                ? AnyShapeStyle(.ultraThinMaterial)
                : AnyShapeStyle(.regularMaterial)

            self
                // 🔴🔴 下面三层的 `.allowsHitTesting(false)` **一个都不能删**！
                //
                // 2026-10-06 事故（0.0.110）：给「加厚毛玻璃」加了一层
                // `.overlay(RoundedRectangle().fill(LinearGradient(...)))` 做顶部高光 ——
                // 那是一个**填充**形状，而 `.overlay` 是**盖在内容上面**的。
                // SwiftUI 里填充形状（以及 `Color`）**参与命中测试**，
                // 于是它把整张卡片的点击、长按、滚动**全吃掉了**。
                //
                // 症状：老板装完 0.0.110 后「用户协议划不动」「一个按钮都点不动」——
                // `aevisGlass` 是全 App 唯一的卡片入口（203 处 / 58 个文件），
                // 所以等于**整机所有可点的地方一起失效**（登录页、设备码页、
                // 设置页、聊天页…）。
                //
                // ⚠️ 为什么 CI 截图没抓到：截图只反映「渲染」，命中测试坏了
                //    截图**完全看不出来**（图是好的，就是点不进去）。
                // ⚠️ 老代码那层是 `strokeBorder` —— 只有那 0.5pt 的**边框**有命中区，
                //    所以从没出过这个问题。**改成 `fill` 就会出事。**
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(material)
                        .allowsHitTesting(false)
                )
                // 顶部内高光：光像从上面打进来，玻璃才「厚」
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.22), .clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .allowsHitTesting(false)
                )
                // 双色高光描边：顶部亮边 + 底部暗边 —— 这一笔最像真玻璃
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.60),
                                    Color.white.opacity(0.10),
                                    Color.black.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                        .allowsHitTesting(false)
                )
                // 柔光外阴影：玻璃微微浮起来（阴影本来就不参与命中测试，不用管）
                .shadow(color: Color.black.opacity(0.07), radius: 8, x: 0, y: 3)
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                        .allowsHitTesting(false)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        .allowsHitTesting(false)
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

/// 背景用**哪一套**设置。用户 2026-10-05 定的规矩：
/// 「选开始页……我要是选哪背景是聊天就是点进那个聊天框，其他的不要」。
///
/// - `.start`：**开始页**（门禁 / 登录 / 主界面那一层底）→ 用「开始页背景」那套。
/// - `.chat` ：**聊天页** → 用「聊天背景」那套（也就是**原来那一套**设置）。
/// - `.base` ：**其余所有二级页面** → **固定素色底，不读任何用户设置**。
///
/// ⭐ 默认值就是 `.base` —— 所以老的 `AevisBackground()` 调用点**一行都不用改**，
///    自动变成"不跟随"。只有开始页和聊天页两处显式传 `.start` / `.chat`。
enum AevisBackgroundScope {
    case start
    case chat
    case base
}

/// 聊天背景。默认给一个「光晕」，但用户能换成纯色、纸感或自己的图片。
///
/// ⚠️ 现在**按 `scope` 取哪一组设置**：开始页一套、聊天页一套、其余素色底。
struct AevisBackground: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme

    /// 这套背景取哪一组设置。**默认 `.base`（不跟随）** —— 见 `AevisBackgroundScope`。
    var scope: AevisBackgroundScope = .base

    /// 当前 scope 对应的一组取色 / 取图参数。
    ///
    /// 抽出来是为了避免 `body` / `customImage` / `scrimOpacity` 里
    /// 把同一段 switch 抄三遍。
    private struct Skin {
        let style: BackgroundStyle
        let data: Data?
        let dim: Double
    }

    private var skin: Skin {
        switch scope {
        case .start:
            return Skin(style: settings.startBackgroundStyle,
                        data: settings.startCustomBackgroundData,
                        dim: settings.startBackgroundDim)
        case .chat:
            return Skin(style: settings.backgroundStyle,
                        data: settings.customBackgroundData,
                        dim: settings.backgroundDim)
        case .base:
            // 素色底：**不读任何用户设置** —— 固定走 `plain` 那档的 base 色
            //（跟随深浅色）。这里绝不能出现自定义图或光晕。
            return Skin(style: .plain, data: nil, dim: 0)
        }
    }

    var body: some View {
        ZStack {
            switch skin.style {
            case .white:
                pureWhite
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

    /// 纯白：始终是白色，不随深浅色变。
    private var pureWhite: Color {
        Color.white
    }

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
        if let data = skin.data, let image = ImageDecodeCache.image(for: data) {
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
        let extra = min(max(skin.dim, 0), 0.8)
        return scheme == .dark ? 0.08 + extra : 0.04 + extra
    }
}

/// ta 的雏形：一团会呼吸的光。跟随主题色。
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
    ///
    /// ⚠️ 这里**不加 private**：这个 struct 是被跨文件全参构造的
    /// （`AevisBubble(text:look:...)`），而 private 存储属性有可能让
    /// memberwise initializer 一起降成 private，别的文件就构造不了了。
    /// 加个默认值就够了，效果一样。
    @ObservedObject var emoji = EmojiPack.shared

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
            .textSelection(.enabled)
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

/// ta 的头像，或者「我」的头像。
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
    /// 直接指定一张图 —— 通讯录/会话列表里要显示**别的联系人**的头像时用。
    /// 不给就按 `source` 走原来的逻辑（当前联系人 / 我）。
    var image: UIImage? = nil

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
        if let image { return image }
        switch source {
        case .ai: return personaStore.avatarImage
        case .me: return profileStore.avatarImage
        }
    }

    /// 没上传照片时的兜底颜色。我的固定用一个青色，和 ta 区分开。
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
