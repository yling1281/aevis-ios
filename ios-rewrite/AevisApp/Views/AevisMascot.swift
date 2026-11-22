import SwiftUI

/// Aevis 品牌吉祥物 —— 官网 `unified_site/assets/icon-new.svg` 的矢量重绘。
///
/// 不用任何图片资源、不用 SF Symbol：狗脸（垂耳 / 笑眼 / ω 嘴 / 鼻子 / 腮红）
/// 全部按 SVG 的 `viewBox="0 0 1024 1024"` 用 `Path` 精确画出（坐标 × size/1024）。
/// 背景用奶油底 + 柔紫 / 暖橙径向光晕 + 四颗四角星，与官网 logo 同一视觉语言。
///
/// 用法：`AevisMascot(size: 76)`
struct AevisMascot: View {
    var size: CGFloat = 76

    var body: some View {
        ZStack {
            // 奶油底 #FFF8EC
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.hex(0xFFF8EC))

            // 暖橙光晕（SVG radialGradient warm：cx 0.16 / cy 0.92）
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.hex(0xFFC6A6).opacity(0.5),
                    Color.hex(0xFFD9C2).opacity(0)
                ]),
                center: UnitPoint(x: 0.16, y: 0.92),
                startRadius: 0,
                endRadius: size * 0.72
            )

            // 柔紫光晕（SVG radialGradient bloom：cx 0.74 / cy 0.14）
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.hex(0xC9BBFF).opacity(0.95),
                    Color.hex(0xDED6FF).opacity(0.5),
                    Color.hex(0xEFEAFF).opacity(0)
                ]),
                center: UnitPoint(x: 0.74, y: 0.14),
                startRadius: 0,
                endRadius: size * 0.86
            )

            // 中央柔白 halo（SVG radialGradient halo）
            RadialGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0)]),
                center: .center,
                startRadius: 0,
                endRadius: size * 0.42
            )

            // 矢量狗脸本体
            Canvas { ctx, s in
                let k = s.width / 1024
                let pt = { (x: CGFloat, y: CGFloat) -> CGPoint in
                    CGPoint(x: x * k, y: y * k)
                }
                let rel = { (bx: CGFloat, by: CGFloat, dx: CGFloat, dy: CGFloat) -> CGPoint in
                    CGPoint(x: (bx + dx) * k, y: (by + dy) * k)
                }

                let ink = Color.hex(0x1F2D3F)

                // MARK: 四颗四角星（SVG 里是同一条相对路径平移四次）
                func star(_ sx: CGFloat, _ sy: CGFloat) -> Path {
                    var p = Path()
                    p.move(to: pt(sx, sy))
                    p.addCurve(to: rel(sx, sy, 24, -24),
                               control1: rel(sx, sy, 3, -15),
                               control2: rel(sx, sy, 9, -21))
                    let b2x = sx + 24, b2y = sy - 24
                    p.addCurve(to: rel(b2x, b2y, -24, -24),
                               control1: rel(b2x, b2y, -15, -3),
                               control2: rel(b2x, b2y, -21, -9))
                    let b3x = b2x - 24, b3y = b2y - 24
                    p.addCurve(to: rel(b3x, b3y, -24, 24),
                               control1: rel(b3x, b3y, -3, 15),
                               control2: rel(b3x, b3y, -9, 21))
                    let b4x = b3x - 24, b4y = b3y + 24
                    p.addCurve(to: rel(b4x, b4y, 24, 24),
                               control1: rel(b4x, b4y, 15, 3),
                               control2: rel(b4x, b4y, 21, 9))
                    p.closeSubpath()
                    return p
                }
                ctx.fill(star(168, 226), with: .color(Color.hex(0xB3A0F2).opacity(0.85)))
                ctx.fill(star(852, 300), with: .color(Color.hex(0xF0A6BE).opacity(0.65)))
                ctx.fill(star(186, 780), with: .color(Color.hex(0xF0A6BE).opacity(0.55)))
                ctx.fill(star(846, 796), with: .color(Color.hex(0xB3A0F2).opacity(0.8)))

                // 描边统一 42（SVG stroke-width），圆头圆角
                let outline = StrokeStyle(lineWidth: 42 * k, lineCap: .round, lineJoin: .round)

                // MARK: 两只垂耳（淡紫填充 + 墨色描边）
                var leftEar = Path()
                leftEar.move(to: pt(370, 292))
                leftEar.addCurve(to: pt(210, 566), control1: pt(272, 306), control2: pt(212, 424))
                leftEar.addCurve(to: pt(298, 742), control1: pt(208, 668), control2: pt(246, 744))
                leftEar.addCurve(to: pt(356, 672), control1: pt(342, 740), control2: pt(356, 710))
                leftEar.addCurve(to: pt(344, 470), control1: pt(356, 600), control2: pt(344, 520))
                leftEar.closeSubpath()
                ctx.fill(leftEar, with: .color(Color.hex(0xF1EAFF)))
                ctx.stroke(leftEar, with: .color(ink), style: outline)

                var rightEar = Path()
                rightEar.move(to: pt(654, 292))
                rightEar.addCurve(to: pt(814, 566), control1: pt(752, 306), control2: pt(812, 424))
                rightEar.addCurve(to: pt(726, 742), control1: pt(816, 668), control2: pt(778, 744))
                rightEar.addCurve(to: pt(668, 672), control1: pt(682, 740), control2: pt(668, 710))
                rightEar.addCurve(to: pt(680, 470), control1: pt(668, 600), control2: pt(680, 520))
                rightEar.closeSubpath()
                ctx.fill(rightEar, with: .color(Color.hex(0xF1EAFF)))
                ctx.stroke(rightEar, with: .color(ink), style: outline)

                // MARK: 白脸圆角矩形（x316 y264 w392 h404 rx134）
                let face = Path(
                    roundedRect: CGRect(x: 316 * k, y: 264 * k, width: 392 * k, height: 404 * k),
                    cornerRadius: 134 * k,
                    style: .circular
                )
                ctx.fill(face, with: .color(.white))
                ctx.stroke(face, with: .color(ink), style: outline)

                // MARK: 弯弯的笑眼（Q430 420 / Q594 420）
                var eyeL = Path()
                eyeL.move(to: pt(398, 456))
                eyeL.addQuadCurve(to: pt(462, 456), control: pt(430, 420))
                var eyeR = Path()
                eyeR.move(to: pt(562, 456))
                eyeR.addQuadCurve(to: pt(626, 456), control: pt(594, 420))
                ctx.stroke(eyeL, with: .color(ink), style: outline)
                ctx.stroke(eyeR, with: .color(ink), style: outline)

                // MARK: ω 形嘴（一竖 + 两条对称曲线）
                var stem = Path()
                stem.move(to: pt(512, 562))
                stem.addLine(to: pt(512, 582))
                var mouthL = Path()
                mouthL.move(to: pt(512, 582))
                mouthL.addCurve(to: pt(460, 604), control1: pt(512, 612), control2: pt(478, 626))
                var mouthR = Path()
                mouthR.move(to: pt(512, 582))
                mouthR.addCurve(to: pt(564, 604), control1: pt(512, 612), control2: pt(546, 626))
                ctx.stroke(stem, with: .color(ink), style: outline)
                ctx.stroke(mouthL, with: .color(ink), style: outline)
                ctx.stroke(mouthR, with: .color(ink), style: outline)

                // MARK: 墨色鼻子（SVG 四个相对 q 命令换算成绝对坐标）
                var nose = Path()
                nose.move(to: pt(512, 518))
                nose.addQuadCurve(to: pt(538, 537), control: pt(538, 518))
                nose.addQuadCurve(to: pt(512, 555), control: pt(538, 555))
                nose.addQuadCurve(to: pt(486, 537), control: pt(486, 555))
                nose.addQuadCurve(to: pt(512, 518), control: pt(486, 518))
                nose.closeSubpath()
                ctx.fill(nose, with: .color(ink))

                // MARK: 粉色腮红（cx374/cx650, cy536, rx38 ry23）
                let blush = Color.hex(0xFF9BB0).opacity(0.5)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: 336 * k, y: 513 * k, width: 76 * k, height: 46 * k)),
                    with: .color(blush)
                )
                ctx.fill(
                    Path(ellipseIn: CGRect(x: 612 * k, y: 513 * k, width: 76 * k, height: 46 * k)),
                    with: .color(blush)
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
