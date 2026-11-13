import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// ============================================================================
// Aevis · 设计系统 v2（2026-11-01 晚 · 跟安卓同款「可爱一点」）
//
// 为什么重做：老板看完别人的界面，说我们「太硬」——
// 安卓那半边已经按这套重画过了（`AevisNative/.../ui/v2/Design.kt`），
// iOS 这里要把**同一套观感**接过来，不然两端像两个 App。
//
// 这套的规矩（改之前先读一遍，别又写回玻璃+粗边）：
//
//   · 底是**米白**（#FAF7F1 / 暖黑 #16151A），
//     白卡片浮在上面才有「纸」的感觉，直接放纯白底上会发灰；
//   · 圆角放大：卡 22、行 18，描边只留 0.5pt、几乎看不见 ——
//     「软」是靠圆角和留白撑的，不是靠阴影；
//   · 字号整体降一档，标题 Semibold 不到 Bold（粗 = 硬）；
//   · 主色只出现在**该被看见的地方**（按钮、选中、数字），
//     其它地方用主色 12%~14% 的淡底，像水彩蹭上去一层；
//   · 图标底从圆角方块改成**圆形**，比方块软；
//   · 空状态/头像位放一只**手绘小猫**（矢量画的，换主题色它跟着变）。
//
// ⚠️ 这一页所有组件**都不套 `.aevisGlass`**。
//    「我」页那次闪退（一屏二十多个 glassEffect）之后定下的规矩：
//    v2 的页面走纯色 + 细描边，别再把液态玻璃堆回来。
// ============================================================================

enum V2 {
    // MARK: - 尺寸
    static let cardRadius: CGFloat = 22
    static let rowRadius: CGFloat = 18
    static let gutter: CGFloat = 18
    static let iconBox: CGFloat = 38
    static let iconRadius: CGFloat = 13

    static let display: CGFloat = 26
    static let title: CGFloat = 20
    static let body: CGFloat = 15
    static let sub: CGFloat = 13.5
    static let tiny: CGFloat = 12
    static let micro: CGFloat = 11

    // MARK: - 颜色（跟着深浅色自动切）

    /// 页面底：奶油白 / 暖黑。
    static let background = dyn(0xFAF7F1, 0x16151A)   // 米白（2026-11-13）
    /// 卡片底。
    static let card = dyn(0xFFFFFF, 0x1E1D26)
    /// 卡片描边：极淡。
    static let stroke = Color.primary.opacity(0.07)
    /// 卡片里的浅色垫底（图标块、分段选择器的槽）。
    static let well = dyn(0xF1F0F8, 0x272530)
    /// 未读/警示的小红点。
    static let alert = Color(red: 0.898, green: 0.282, blue: 0.302)

    /// 次要文字。
    static func dim(_ alpha: Double = 0.5) -> Color {
        Color.primary.opacity(alpha)
    }

    /// 主色。**每次都现读设置** —— 用户在「外观」里换色要立刻生效。
    static var accent: Color { AppSettings.shared.accentColor }

    /// 主色的淡底（水彩那层）。
    static func soft(_ alpha: Double = 0.12) -> Color {
        AppSettings.shared.accentColor.opacity(alpha)
    }

    // MARK: - 颜色工具

    private static func ui(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }

    /// 深浅色各给一个值。
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? ui(dark) : ui(light)
        })
    }
}

// MARK: - 卡片

/// 一张卡：22 圆角、纯色、0.5pt 细边、**没有阴影**（阴影会显脏）。
///
/// 注意两个背景层都加了 `.allowsHitTesting(false)`
/// —— 见 `GlassSurface.swift` 里 0.0.110 那次「整机按钮全点不动」的事故。
struct V2Card<Content: View>: View {
    var color: Color?
    var radius: CGFloat
    @ViewBuilder var content: Content

    init(color: Color? = nil,
         radius: CGFloat = V2.cardRadius,
         @ViewBuilder content: () -> Content) {
        self.color = color
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color ?? V2.card)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(V2.stroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}

/// 行与行之间那条细线（左边让出图标宽度）。
struct V2Divider: View {
    var leading: CGFloat = 66

    var body: some View {
        Rectangle()
            .fill(V2.stroke)
            .frame(height: 0.5)
            .padding(.leading, leading)
            .allowsHitTesting(false)
    }
}

// MARK: - 图标 / 头像

/// 圆形的柔色图标底。比原来的圆角方块软。
struct V2IconBox: View {
    var symbol: String
    var tint: Color?
    var size: CGFloat

    init(_ symbol: String, tint: Color? = nil, size: CGFloat = V2.iconBox) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    private var color: Color { tint ?? V2.accent }

    var body: some View {
        Image(systemName: symbol)
            .font(.aevis(size * 0.46, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.13)))
            .clipShape(Circle())
    }
}

/// 头像：圆形柔底，有字取首字，没字用小猫。
struct V2Avatar: View {
    var text: String
    var size: CGFloat
    var tint: Color?

    init(_ text: String, size: CGFloat = 48, tint: Color? = nil) {
        self.text = text
        self.size = size
        self.tint = tint
    }

    private var color: Color { tint ?? V2.accent }

    private var initial: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : String(trimmed.prefix(1))
    }

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.14))
            if initial.isEmpty {
                V2CatFace(size: size * 0.62, tint: color)
            } else {
                Text(initial)
                    .font(.aevis(size * 0.38, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - 行

/// 一行入口。
///
/// - `badge` 大于 0 时右侧显示红点数字（站内信未读）
/// - `trailing` 是右边那句灰色小字
struct V2Row: View {
    var symbol: String
    var title: String
    var detail: String?
    var trailing: String?
    var badge: Int
    var tint: Color?
    var showsChevron: Bool
    var action: (() -> Void)?

    init(symbol: String,
         title: String,
         detail: String? = nil,
         trailing: String? = nil,
         badge: Int = 0,
         tint: Color? = nil,
         showsChevron: Bool = true,
         action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.badge = badge
        self.tint = tint
        self.showsChevron = showsChevron
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 13) {
            V2IconBox(symbol, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.aevis(V2.body, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.aevis(V2.tiny))
                        .foregroundStyle(V2.dim(0.45))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if badge > 0 {
                Text(badge > 99 ? "99+" : "\(badge)")
                    .font(.aevis(V2.micro, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(V2.alert))
            }

            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.aevis(V2.tiny))
                    .foregroundStyle(V2.dim(0.35))
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(V2.dim(0.22))
            }
        }
        .padding(.horizontal, V2.gutter)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 「标签 —— 值」一行，设置/资料页成组用。
struct V2InfoRow: View {
    var label: String
    var value: String
    var last: Bool

    init(_ label: String, _ value: String, last: Bool = false) {
        self.label = label
        self.value = value
        self.last = last
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.aevis(V2.body))
                    .foregroundStyle(.primary)
                Spacer(minLength: 10)
                Text(value)
                    .font(.aevis(V2.sub))
                    .foregroundStyle(V2.dim(0.42))
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 14)
            if !last { V2Divider(leading: V2.gutter) }
        }
    }
}

// MARK: - 标题

/// 区块标题：小、灰、轻。
struct V2SectionTitle: View {
    var text: String
    var trailing: String?
    var onTrailing: (() -> Void)?

    init(_ text: String, trailing: String? = nil, onTrailing: (() -> Void)? = nil) {
        self.text = text
        self.trailing = trailing
        self.onTrailing = onTrailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.aevis(V2.sub, weight: .medium))
                .foregroundStyle(V2.dim(0.5))
            Spacer(minLength: 8)
            if let trailing, let onTrailing {
                Button(action: onTrailing) {
                    Text(trailing)
                        .font(.aevis(V2.tiny))
                        .foregroundStyle(V2.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, V2.gutter)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// 顶部大标题栏：左标题（可带副标题），右边留给动作。
struct V2TopBar<Trailing: View>: View {
    var title: String
    var subtitle: String?
    var trailing: Trailing

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.aevis(V2.title, weight: .semibold))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.aevis(V2.tiny))
                        .foregroundStyle(V2.dim(0.42))
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, V2.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

extension V2TopBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - 小零件

/// 小标签（胶囊）。
struct V2Pill: View {
    var text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    private var tint: Color { color ?? V2.accent }

    var body: some View {
        Text(text)
            .font(.aevis(V2.micro, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// 主按钮：整颗胶囊、实心主色、白字。
struct V2PrimaryButton: View {
    var title: String
    var enabled: Bool
    var action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.aevis(V2.body, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Capsule().fill(V2.accent.opacity(enabled ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 次按钮：淡主色底 + 主色字，没有描边。
struct V2SoftButton: View {
    var title: String
    var action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.aevis(V2.sub, weight: .medium))
                .foregroundStyle(V2.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(V2.accent.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

/// 用量进度条：粗胶囊，快用完时转琥珀色。
struct V2ProgressBar: View {
    var fraction: Double
    var height: CGFloat

    init(_ fraction: Double, height: CGFloat = 12) {
        self.fraction = fraction
        self.height = height
    }

    private var clamped: Double { min(max(fraction, 0.02), 1) }

    private var tone: Color {
        if clamped <= 0.15 { return Color(red: 0.851, green: 0.514, blue: 0.141) }
        if clamped <= 0.35 { return Color(red: 0.788, green: 0.635, blue: 0.153) }
        return V2.accent
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tone.opacity(0.16))
                Capsule()
                    .fill(tone.opacity(0.8))
                    .frame(width: max(geo.size.width * CGFloat(clamped), height))
            }
        }
        .frame(height: height)
    }
}

/// 服务宫格里的一个格子。
struct V2ServiceTile: View {
    var symbol: String
    var title: String
    var dot: Bool
    var action: () -> Void

    init(_ symbol: String, _ title: String, dot: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.dot = dot
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.aevis(21, weight: .medium))
                        .foregroundStyle(V2.accent)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(V2.accent.opacity(0.10))
                        )
                    if dot {
                        Circle()
                            .fill(V2.alert)
                            .frame(width: 8, height: 8)
                    }
                }
                Text(title)
                    .font(.aevis(V2.tiny))
                    .foregroundStyle(V2.dim(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 空状态 / 吉祥物

/// 空状态：一只小猫 + 一句话（可选一行提示）。
struct V2Empty: View {
    var text: String
    var hint: String?

    init(_ text: String, hint: String? = nil) {
        self.text = text
        self.hint = hint
    }

    var body: some View {
        VStack(spacing: 12) {
            V2CatFace(size: 64, tint: V2.dim(0.18))
            Text(text)
                .font(.aevis(V2.sub))
                .foregroundStyle(V2.dim(0.45))
                .multilineTextAlignment(.center)
            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.aevis(V2.tiny))
                    .foregroundStyle(V2.dim(0.3))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// 吉祥物：一只只画轮廓的小猫。
///
/// 为什么自己画而不是塞图片：矢量在什么屏幕上都不糊，颜色跟着主色走，
/// 用户换主题色时它一起变（不会出现「紫色按钮配蓝色猫」）。
struct V2CatFace: View {
    var size: CGFloat
    var tint: Color

    init(size: CGFloat = 56, tint: Color? = nil) {
        self.size = size
        self.tint = tint ?? V2.accent
    }

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height) / 24

            // 耳朵 + 脸：一笔画成，像铅笔随手勾的
            var head = Path()
            head.move(to: CGPoint(x: 4.2 * s, y: 10.4 * s))
            head.addLine(to: CGPoint(x: 5.2 * s, y: 3.6 * s))
            head.addLine(to: CGPoint(x: 10.4 * s, y: 6.8 * s))
            head.addLine(to: CGPoint(x: 13.6 * s, y: 6.8 * s))
            head.addLine(to: CGPoint(x: 18.8 * s, y: 3.6 * s))
            head.addLine(to: CGPoint(x: 19.8 * s, y: 10.4 * s))
            head.addCurve(to: CGPoint(x: 12 * s, y: 20.4 * s),
                          control1: CGPoint(x: 19.8 * s, y: 16.6 * s),
                          control2: CGPoint(x: 16.2 * s, y: 20.4 * s))
            head.addCurve(to: CGPoint(x: 4.2 * s, y: 10.4 * s),
                          control1: CGPoint(x: 7.8 * s, y: 20.4 * s),
                          control2: CGPoint(x: 4.2 * s, y: 16.6 * s))
            head.closeSubpath()
            ctx.stroke(head,
                       with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.8 * s, lineCap: .round, lineJoin: .round))

            // 眼睛：两道小弧（闭着眼笑的那种）
            var leftEye = Path()
            leftEye.addArc(center: CGPoint(x: 8.7 * s, y: 11.7 * s),
                           radius: 1.3 * s,
                           startAngle: .degrees(200),
                           endAngle: .degrees(340),
                           clockwise: false)
            ctx.stroke(leftEye,
                       with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round))

            var rightEye = Path()
            rightEye.addArc(center: CGPoint(x: 15.3 * s, y: 11.7 * s),
                            radius: 1.3 * s,
                            startAngle: .degrees(200),
                            endAngle: .degrees(340),
                            clockwise: false)
            ctx.stroke(rightEye,
                       with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round))

            // 小嘴：一道往上的弧
            var mouth = Path()
            mouth.addArc(center: CGPoint(x: 12 * s, y: 13.4 * s),
                         radius: 1.4 * s,
                         startAngle: .degrees(20),
                         endAngle: .degrees(160),
                         clockwise: false)
            ctx.stroke(mouth,
                       with: .color(tint),
                       style: StrokeStyle(lineWidth: 1.6 * s, lineCap: .round))

            // 两颊腮红：一点点，不要变成猴子屁股
            let blush = tint.opacity(0.20)
            ctx.fill(Path(ellipseIn: CGRect(x: 5.1 * s, y: 12.0 * s,
                                            width: 3.0 * s, height: 2.8 * s)),
                     with: .color(blush))
            ctx.fill(Path(ellipseIn: CGRect(x: 15.9 * s, y: 12.0 * s,
                                            width: 3.0 * s, height: 2.8 * s)),
                     with: .color(blush))
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

// MARK: - 页面底

/// 把页面底换成奶油底（v2 页面都套这一个）。
struct V2PageBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(V2.background.ignoresSafeArea())
    }
}

extension View {
    /// 奶油底。**v2 的页面都该套它** —— 不然白卡片会落在默认灰底上，显脏。
    func v2Page() -> some View {
        modifier(V2PageBackground())
    }
}
