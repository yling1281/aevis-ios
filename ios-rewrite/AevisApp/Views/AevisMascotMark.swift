import SwiftUI

/// Aevis 品牌狗头 —— **无底版**（完全透明，画布里只有狗头本身）。
///
/// 造型与 `AevisMascot` 同源：坐标仍取官网 `unified_site/assets/icon-new.svg`
/// 的 `viewBox="0 0 1024 1024"`，垂耳 / 白脸 / 笑眼 / ω 嘴 / 鼻子 / 腮红的
/// 控制点一一对应，只是**不再画奶油底、径向光晕和四角星**，
/// 所以可以直接叠在任意底色、头像圆、毛玻璃卡片上。
///
/// 分工：
/// - **本文件（无底）**：头像位、额度卡大图、空状态插画；
/// - **`AevisMascot`（带奶油底）**：需要「一整块图标」的场合（登录页角落、更新弹窗）。
///
/// `size` 是**宽度**，高度 = `size * 0.8286`（画框按狗头紧边界裁过，不再留方形空白）。
/// 96pt 以上细节完整，28pt 仍清晰，24pt 可辨认（此时建议 `.front` + `tint` 单色）。
///
/// 全部纯 `Path` 绘制，不依赖图片资源、不依赖 SF Symbol。
/// 缩放统一走 1024 坐标系 → 画布：`k = size / 700`，无任何写死像素。
struct AevisMascotMark: View {
    /// 四种姿态。差异都在 `apply(_:to:center:k:)` 与眼睛的分支里。
    enum Pose: String, CaseIterable {
        /// 正面：官网 logo 原样（笑眼 + ω 嘴），默认
        case front
        /// 歪头：整体 -8° 旋转 + 视线向右下偏移，耳朵随头倾斜
        case tilt
        /// 眨眼：右眼由「∩ 笑眼」换成「⌣ 闭眼」，左眼仍是笑眼
        case wink
        /// 打盹：双眼闭合 + 右上角两个 Z，整体缩小左移，像缩在角落里睡
        case sleep
    }

    var pose: Pose = .front
    var size: CGFloat = 96
    /// nil = 品牌配色（墨线 + 白脸 + 淡紫耳 + 官网粉腮红）；
    /// 传值 = 整体单色（线条与五官都用它，脸/耳不着色，小尺寸更干净）。
    var tint: Color? = nil

    // MARK: - 画框：1024 空间里裁到狗头紧边界（含 42 描边的半宽 21）
    // 狗头本体：x 189…835，y 243…763 → 左右各留 27，上下留 31 / 29（多留的余量给歪头与 Z）
    private static let boxX: CGFloat = 162
    private static let boxY: CGFloat = 212
    private static let boxW: CGFloat = 700
    private static let boxH: CGFloat = 580

    /// 给定宽度算实际高度（调用方排版要用，比如放在 HStack 里预留空间）
    static func height(forWidth width: CGFloat) -> CGFloat {
        width * boxH / boxW
    }

    var body: some View {
        Canvas { ctx, sz in
            let g = Geo(k: sz.width / Self.boxW, ox: Self.boxX, oy: Self.boxY)
            let pal = Self.palette(tint)

            // 「Z」要画在**未变换**的坐标系里，先把原始 context 拷一份
            let flat = ctx

            Self.apply(pose, to: &ctx, center: g.p(512, 503), k: g.k)
            Self.drawHead(&ctx, g: g, pose: pose, pal: pal)

            if pose == .sleep {
                Self.drawZs(flat, g: g, ink: pal.ink)
            }
        }
        .frame(width: size, height: Self.height(forWidth: size))
        .accessibilityLabel("Aevis")
    }
}

// MARK: - 尺寸友好入口

extension AevisMascotMark {
    /// 头像占位：正面 + 单色（柔紫线稿）。
    /// `size` 传**头像圆的直径**；内部按 0.80 缩放，保证垂耳尖角不被圆形裁剪切掉。
    static func avatarPlaceholder(size: CGFloat) -> AevisMascotMark {
        AevisMascotMark(pose: .front, size: size * 0.80, tint: AE.brandPurple)
    }

    /// 额度卡 / 空状态大图：品牌彩色正面，建议 96…120pt。
    static func heroCard(size: CGFloat) -> AevisMascotMark {
        AevisMascotMark(pose: .front, size: size)
    }
}

// MARK: - 绘制实现

private extension AevisMascotMark {

    /// 配色表
    struct Palette {
        let ink: Color    // 描边 + 五官
        let face: Color   // 脸填充
        let ear: Color    // 耳填充
        let blush: Color  // 腮红
    }

    static func palette(_ tint: Color?) -> Palette {
        if let t = tint {
            // 单色：只留线条与五官。脸/耳填透明，小尺寸下不会糊成一坨色块
            return Palette(ink: t, face: .clear, ear: .clear, blush: t.opacity(0.35))
        }
        return Palette(
            ink: AE.brandInk,                    // #1F2D3F（深色模式自动提亮）
            face: .white,                        // 官网白脸
            ear: AE.brandLilac,                  // #F1EAFF 淡紫耳
            blush: Color.hex(0xFF9BB0).opacity(0.50)   // 官网粉腮红（与 icon-new.svg 一致）
        )
    }

    /// 1024 SVG 坐标 → 画布坐标
    struct Geo {
        let k: CGFloat
        let ox: CGFloat
        let oy: CGFloat

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - ox) * k, y: (y - oy) * k)
        }

        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: (x - ox) * k, y: (y - oy) * k, width: w * k, height: h * k)
        }

        func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Path {
            Path(ellipseIn: CGRect(
                x: (cx - rx - ox) * k,
                y: (cy - ry - oy) * k,
                width: 2 * rx * k,
                height: 2 * ry * k
            ))
        }
    }

    /// 每个姿态的整体变换：(缩放, 旋转角, 平移 dx/dy —— 平移用 1024 空间单位)
    static func poseTransform(_ pose: Pose) -> (s: CGFloat, deg: Double, dx: CGFloat, dy: CGFloat) {
        switch pose {
        case .front: return (1.00, 0, 0, 0)
        case .wink:  return (1.00, 0, 0, 0)
        // 转 8° 后包围盒会变宽变高，缩到 0.92 才塞得进画框（余量最小处 18）
        case .tilt:  return (0.92, -8, 4, 6)
        // 缩小左移，给右上角的两个 Z 腾位置
        case .sleep: return (0.80, -3, -34, 28)
        }
    }

    static func apply(_ pose: Pose, to ctx: inout GraphicsContext, center c: CGPoint, k: CGFloat) {
        let t = poseTransform(pose)
        if t.s == 1, t.deg == 0, t.dx == 0, t.dy == 0 { return }
        // 平移到中心 → 旋转 → 缩放 → 移回：绕 (512,503) 也就是脸的中心变换
        ctx.translateBy(x: c.x + t.dx * k, y: c.y + t.dy * k)
        ctx.rotate(by: .degrees(t.deg))
        ctx.scaleBy(x: t.s, y: t.s)
        ctx.translateBy(x: -c.x, y: -c.y)
    }

    /// 狗头本体：耳 → 脸 → 眼 → 嘴 → 鼻 → 腮红（顺序即图层顺序）
    static func drawHead(_ ctx: inout GraphicsContext, g: Geo, pose: Pose, pal: Palette) {
        let k = g.k
        // 描边 42 与原 SVG 的 stroke-width 一致，圆头圆角
        let line = StrokeStyle(lineWidth: 42 * k, lineCap: .round, lineJoin: .round)

        // MARK: 两只垂耳（先画，内侧被脸压住）
        for ear in [earPath(g, left: true), earPath(g, left: false)] {
            ctx.fill(ear, with: .color(pal.ear))
            ctx.stroke(ear, with: .color(pal.ink), style: line)
        }

        // MARK: 白脸圆角矩形（x316 y264 w392 h404 rx134）
        let face = Path(
            roundedRect: g.rect(316, 264, 392, 404),
            cornerRadius: 134 * k,
            style: .circular
        )
        ctx.fill(face, with: .color(pal.face))
        ctx.stroke(face, with: .color(pal.ink), style: line)

        // 歪头时视线往右下偏一点（其余姿态不偏）
        let ex: CGFloat = pose == .tilt ? 8 : 0
        let ey: CGFloat = pose == .tilt ? 5 : 0

        // MARK: 眼睛：左眼只打盹闭；右眼眨眼/打盹闭
        let leftEye = pose == .sleep
            ? shutEye(g, cx: 430, shiftX: ex, shiftY: ey)
            : smileEye(g, cx: 430, shiftX: ex, shiftY: ey)
        let rightEye = (pose == .wink || pose == .sleep)
            ? shutEye(g, cx: 594, shiftX: ex, shiftY: ey)
            : smileEye(g, cx: 594, shiftX: ex, shiftY: ey)
        ctx.stroke(leftEye, with: .color(pal.ink), style: line)
        ctx.stroke(rightEye, with: .color(pal.ink), style: line)

        // MARK: ω 形嘴（一竖 + 两条对称曲线，四种姿态都保留品牌嘴型）
        var stem = Path()
        stem.move(to: g.p(512, 562))
        stem.addLine(to: g.p(512, 582))
        var mouthL = Path()
        mouthL.move(to: g.p(512, 582))
        mouthL.addCurve(to: g.p(460, 604), control1: g.p(512, 612), control2: g.p(478, 626))
        var mouthR = Path()
        mouthR.move(to: g.p(512, 582))
        mouthR.addCurve(to: g.p(564, 604), control1: g.p(512, 612), control2: g.p(546, 626))
        for p in [stem, mouthL, mouthR] {
            ctx.stroke(p, with: .color(pal.ink), style: line)
        }

        // MARK: 墨色鼻子（SVG 四个相对 q 命令换算成绝对坐标）
        var nose = Path()
        nose.move(to: g.p(512, 518))
        nose.addQuadCurve(to: g.p(538, 537), control: g.p(538, 518))
        nose.addQuadCurve(to: g.p(512, 555), control: g.p(538, 555))
        nose.addQuadCurve(to: g.p(486, 537), control: g.p(486, 555))
        nose.addQuadCurve(to: g.p(512, 518), control: g.p(486, 518))
        nose.closeSubpath()
        ctx.fill(nose, with: .color(pal.ink))

        // MARK: 腮红（cx374 / cx650，cy536，rx38 ry23）
        ctx.fill(g.ellipse(cx: 374, cy: 536, rx: 38, ry: 23), with: .color(pal.blush))
        ctx.fill(g.ellipse(cx: 650, cy: 536, rx: 38, ry: 23), with: .color(pal.blush))
    }

    /// 垂耳：直接照搬 SVG 的两条 path（只把相对控制点换成绝对坐标）
    static func earPath(_ g: Geo, left: Bool) -> Path {
        var p = Path()
        if left {
            p.move(to: g.p(370, 292))
            p.addCurve(to: g.p(210, 566), control1: g.p(272, 306), control2: g.p(212, 424))
            p.addCurve(to: g.p(298, 742), control1: g.p(208, 668), control2: g.p(246, 744))
            p.addCurve(to: g.p(356, 672), control1: g.p(342, 740), control2: g.p(356, 710))
            p.addCurve(to: g.p(344, 470), control1: g.p(356, 600), control2: g.p(344, 520))
        } else {
            p.move(to: g.p(654, 292))
            p.addCurve(to: g.p(814, 566), control1: g.p(752, 306), control2: g.p(812, 424))
            p.addCurve(to: g.p(726, 742), control1: g.p(816, 668), control2: g.p(778, 744))
            p.addCurve(to: g.p(668, 672), control1: g.p(682, 740), control2: g.p(668, 710))
            p.addCurve(to: g.p(680, 470), control1: g.p(668, 600), control2: g.p(680, 520))
        }
        p.closeSubpath()
        return p
    }

    /// 笑眼：∩ 形上弯弧（原 SVG `M398 456 Q430 420 462 456`，cx=430）
    static func smileEye(_ g: Geo, cx: CGFloat, shiftX: CGFloat, shiftY: CGFloat) -> Path {
        var p = Path()
        p.move(to: g.p(cx - 32 + shiftX, 456 + shiftY))
        p.addQuadCurve(
            to: g.p(cx + 32 + shiftX, 456 + shiftY),
            control: g.p(cx + shiftX, 420 + shiftY)
        )
        return p
    }

    /// 闭眼：⌣ 形下弯弧（与笑眼曲率相反，一眼能看出是闭着/眨眼）
    static func shutEye(_ g: Geo, cx: CGFloat, shiftX: CGFloat, shiftY: CGFloat) -> Path {
        var p = Path()
        p.move(to: g.p(cx - 30 + shiftX, 446 + shiftY))
        p.addQuadCurve(
            to: g.p(cx + 30 + shiftX, 446 + shiftY),
            control: g.p(cx + shiftX, 492 + shiftY)
        )
        return p
    }

    /// 打盹的两个 Z：近的小、远的大，越飘越淡（都在狗头右上方 730…842 / 228…362 的空区里）
    static func drawZs(_ ctx: GraphicsContext, g: Geo, ink: Color) {
        ctx.stroke(
            zGlyph(g, x: 740, y: 314, w: 40, h: 38),
            with: .color(ink.opacity(0.92)),
            style: StrokeStyle(lineWidth: 20 * g.k, lineCap: .round, lineJoin: .round)
        )
        ctx.stroke(
            zGlyph(g, x: 780, y: 240, w: 50, h: 46),
            with: .color(ink.opacity(0.62)),
            style: StrokeStyle(lineWidth: 24 * g.k, lineCap: .round, lineJoin: .round)
        )
    }

    /// 一笔写完的 Z：横 → 斜 → 横
    static func zGlyph(_ g: Geo, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        p.move(to: g.p(x, y))
        p.addLine(to: g.p(x + w, y))
        p.addLine(to: g.p(x, y + h))
        p.addLine(to: g.p(x + w, y + h))
        return p
    }
}
