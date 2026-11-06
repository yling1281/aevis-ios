import SwiftUI

/// 全 App 图标。
///
/// 为什么不用 SF Symbols：不同 iOS 版本的字形细节会变（iOS 18 把一批图标重画过），
/// 而且和 Android 那套 Canvas 图标对不上。这里全部用 Path 手画，
/// 归一化坐标（0~1）和 Android 的 `MusicIcons.kt` 一一对应，
/// 两端在同一个视觉语言里，且不依赖任何图标资源。
///
/// 用法：`IcChat(color: Paper.inkMuted, size: 20)`
enum Ic {
    /// 统一画布：把 0~1 的坐标映射到实际尺寸
    static func canvas(_ size: CGFloat, _ draw: (inout Path, CGFloat) -> Void) -> Path {
        var p = Path()
        draw(&p, size)
        return p
    }
}

// MARK: - 会话（对话气泡）
struct IcChat: View {
    var color: Color = Paper.ink
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to: CGPoint(x: w * 0.14, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.20))
            p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.68))
            p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.68))
            p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.86))
            p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.68))
            p.addLine(to: CGPoint(x: w * 0.14, y: h * 0.68))
            p.closeSubpath()
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: w * 0.075, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 发现（罗盘）
struct IcCompass: View {
    var color: Color = Paper.ink
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.075
            let circle = Path(ellipseIn: CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.72, height: h * 0.72))
            ctx.stroke(circle, with: .color(color), style: StrokeStyle(lineWidth: sw))

            var p = Path()
            p.move(to: CGPoint(x: w * 0.62, y: h * 0.36))
            p.addLine(to: CGPoint(x: w * 0.54, y: h * 0.54))
            p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.62))
            p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.46))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 联系人（两个人）
struct IcPeople: View {
    var color: Color = Paper.ink
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.07

            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.225, y: h * 0.225, width: w * 0.23, height: h * 0.23)),
                       with: .color(color), style: StrokeStyle(lineWidth: sw))
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.605, y: h * 0.285, width: w * 0.19, height: h * 0.19)),
                       with: .color(color), style: StrokeStyle(lineWidth: sw))

            var b1 = Path()
            b1.move(to: CGPoint(x: w * 0.14, y: h * 0.80))
            b1.addCurve(to: CGPoint(x: w * 0.54, y: h * 0.80),
                        control1: CGPoint(x: w * 0.14, y: h * 0.60),
                        control2: CGPoint(x: w * 0.54, y: h * 0.60))
            ctx.stroke(b1, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round))

            var b2 = Path()
            b2.move(to: CGPoint(x: w * 0.62, y: h * 0.78))
            b2.addCurve(to: CGPoint(x: w * 0.88, y: h * 0.78),
                        control1: CGPoint(x: w * 0.63, y: h * 0.64),
                        control2: CGPoint(x: w * 0.88, y: h * 0.64))
            ctx.stroke(b2, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 我的（单个人）
struct IcPerson: View {
    var color: Color = Paper.ink
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.075
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.36, y: h * 0.20, width: w * 0.28, height: h * 0.28)),
                       with: .color(color), style: StrokeStyle(lineWidth: sw))

            var p = Path()
            p.move(to: CGPoint(x: w * 0.22, y: h * 0.84))
            p.addCurve(to: CGPoint(x: w * 0.78, y: h * 0.84),
                       control1: CGPoint(x: w * 0.22, y: h * 0.58),
                       control2: CGPoint(x: w * 0.78, y: h * 0.58))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 加号
struct IcPlus: View {
    var color: Color = Paper.ink
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.09
            var p = Path()
            p.move(to: CGPoint(x: w * 0.5, y: h * 0.22))
            p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.78))
            p.move(to: CGPoint(x: w * 0.22, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.5))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 扫一扫（四角取景框）
struct IcScan: View {
    var color: Color = Paper.ink
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.08
            let len = w * 0.22
            let pad = w * 0.16
            let style = StrokeStyle(lineWidth: sw, lineCap: .round)

            // 左上
            var p1 = Path()
            p1.move(to: CGPoint(x: pad, y: h * 0.38))
            p1.addLine(to: CGPoint(x: pad, y: pad))
            p1.addLine(to: CGPoint(x: w * 0.38, y: pad))
            ctx.stroke(p1, with: .color(color), style: style)

            // 右上
            var p2 = Path()
            p2.move(to: CGPoint(x: w - pad, y: h * 0.38))
            p2.addLine(to: CGPoint(x: w - pad, y: pad))
            p2.addLine(to: CGPoint(x: w * 0.62, y: pad))
            ctx.stroke(p2, with: .color(color), style: style)

            // 左下
            var p3 = Path()
            p3.move(to: CGPoint(x: pad, y: h * 0.62))
            p3.addLine(to: CGPoint(x: pad, y: h - pad))
            p3.addLine(to: CGPoint(x: w * 0.38, y: h - pad))
            ctx.stroke(p3, with: .color(color), style: style)

            // 右下
            var p4 = Path()
            p4.move(to: CGPoint(x: w - pad, y: h * 0.62))
            p4.addLine(to: CGPoint(x: w - pad, y: h - pad))
            p4.addLine(to: CGPoint(x: w * 0.62, y: h - pad))
            ctx.stroke(p4, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
    }
}
