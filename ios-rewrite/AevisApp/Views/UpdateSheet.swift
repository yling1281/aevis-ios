import SwiftUI

/// 半屏更新弹窗：强制模式关不掉、进不去；可选模式可「稍后」。
///
/// - 半屏由外层 `.sheet` 的 `.presentationDetents([.medium])` 决定（见 `AevisApp.swift`）。
/// - 强制模式：不显示「稍后」+ 本视图 `.interactiveDismissDisabled(true)`，
///   且外层 Binding 的 set 被忽略，用户下拉手势 / 代码 dismiss 都关不掉。
/// - App 图标用另一个 worker 提供的自绘矢量 `AevisMascot(size:)`，不引入 SF Symbol。
/// - 图标装饰全部为本文件内私有 `Canvas + Path` 矢量，归一化 0~1 坐标。
/// - 文案刻意写明 iOS 的安装限制：点「立即更新」是跳下载/OTA，不是 App 内自动装好。
struct UpdateSheet: View {
    @ObservedObject var center: AppUpdateCenter
    /// logo 轻微呼吸动画的开关（onAppear 后翻转一次触发 repeatForever）
    @State private var breathing = false

    var body: some View {
        if let info = center.latest {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // MARK: App 图标（自家矢量 logo）+ 星星点缀
                    ZStack(alignment: .topTrailing) {
                        AevisMascot(size: 88)
                            .scaleEffect(breathing ? 1.06 : 1.0)
                            .animation(
                                .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                                value: breathing
                            )
                            .padding(18)
                            .background(
                                RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous)
                                    .fill(AE.accentSoft)
                            )
                            .shadow(color: AE.shadowColor, radius: 14, y: 6)
                            .onAppear { breathing = true }

                        Sparkle(color: AE.warm, size: 18)
                            .offset(x: 6, y: -6)
                    }
                    .padding(.top, 6)

                    // MARK: 标题（自绘矢量图标，不用 SF Symbol）
                    HStack(spacing: 8) {
                        if info.force {
                            WarnBadge(color: AE.warm, size: 22)
                        } else {
                            DownloadArrow(color: AE.accent, size: 22)
                        }
                        Text(info.force ? "需要更新后才能继续使用" : "有新版本可用")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                        Spacer(minLength: 0)
                    }

                    Text("当前 \(info.current) · 最新 \(info.latest)")
                        .font(.system(size: 13))
                        .foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // MARK: 更新说明
                    if !info.notes.isEmpty {
                        ScrollView {
                            Text(info.notes)
                                .font(.system(size: 14))
                                .foregroundStyle(AE.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(maxHeight: 110)
                        .background(
                            AE.accentSoft.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }

                    // MARK: 诚实文案 + 小爱心
                    HStack(alignment: .top, spacing: 6) {
                        Heart(color: AE.warm, size: 14)
                            .padding(.top, 2)
                        Text(info.hasOTA
                             ? "将跳转到系统安装页完成更新。"
                             : "将下载安装包（.ipa）。iOS 不允许 App 自行安装，下载后请在「文件」中用签名工具安装。")
                            .font(.system(size: 12))
                            .foregroundStyle(AE.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // MARK: 操作按钮
                    HStack(spacing: 12) {
                        if !info.force {
                            Button { center.dismiss() } label: {
                                Text("稍后")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(AE.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                    .background(
                                        AE.accentSoft,
                                        in: RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Button { center.openInstall() } label: {
                            HStack(spacing: 6) {
                                GiftBox(color: .white, size: 16)
                                Text("立即更新")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                AE.accentDeep,
                                in: RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(20)
            }
            .interactiveDismissDisabled(info.force)
        }
    }
}

// MARK: - 自绘矢量装饰（私有，仅本文件可见；全部 Canvas + Path，归一化 0~1 坐标）

/// 警告徽标：圆角三角形 + 感叹号（强制更新标题旁）
private struct WarnBadge: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.08
            var tri = Path()
            tri.move(to: CGPoint(x: w * 0.5, y: h * 0.10))
            tri.addLine(to: CGPoint(x: w * 0.92, y: h * 0.86))
            tri.addLine(to: CGPoint(x: w * 0.08, y: h * 0.86))
            tri.closeSubpath()
            ctx.stroke(tri, with: .color(color),
                       style: StrokeStyle(lineWidth: sw, lineJoin: .round))

            var bar = Path()
            bar.move(to: CGPoint(x: w * 0.5, y: h * 0.36))
            bar.addLine(to: CGPoint(x: w * 0.5, y: h * 0.62))
            ctx.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: sw, lineCap: .round))

            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.5 - sw * 0.5, y: h * 0.72,
                                            width: sw, height: sw)),
                     with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// 下载箭头：向下箭头落入托盘（可选更新标题旁）
private struct DownloadArrow: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.08
            let style = StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round)

            var shaft = Path()
            shaft.move(to: CGPoint(x: w * 0.5, y: h * 0.14))
            shaft.addLine(to: CGPoint(x: w * 0.5, y: h * 0.62))
            ctx.stroke(shaft, with: .color(color), style: style)

            var head = Path()
            head.move(to: CGPoint(x: w * 0.30, y: h * 0.44))
            head.addLine(to: CGPoint(x: w * 0.5, y: h * 0.64))
            head.addLine(to: CGPoint(x: w * 0.70, y: h * 0.44))
            ctx.stroke(head, with: .color(color), style: style)

            var tray = Path()
            tray.move(to: CGPoint(x: w * 0.18, y: h * 0.80))
            tray.addLine(to: CGPoint(x: w * 0.82, y: h * 0.80))
            ctx.stroke(tray, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
    }
}

/// 四角小星星（logo 旁点缀）
private struct Sparkle: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to: CGPoint(x: w * 0.5, y: h * 0.04))
            p.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.38),
                           control: CGPoint(x: w * 0.56, y: h * 0.18))
            p.addQuadCurve(to: CGPoint(x: w * 0.96, y: h * 0.5),
                           control: CGPoint(x: w * 0.82, y: h * 0.42))
            p.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.62),
                           control: CGPoint(x: w * 0.82, y: h * 0.58))
            p.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.96),
                           control: CGPoint(x: w * 0.56, y: h * 0.82))
            p.addQuadCurve(to: CGPoint(x: w * 0.38, y: h * 0.62),
                           control: CGPoint(x: w * 0.44, y: h * 0.82))
            p.addQuadCurve(to: CGPoint(x: w * 0.04, y: h * 0.5),
                           control: CGPoint(x: w * 0.18, y: h * 0.58))
            p.addQuadCurve(to: CGPoint(x: w * 0.38, y: h * 0.38),
                           control: CGPoint(x: w * 0.18, y: h * 0.42))
            p.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.04),
                           control: CGPoint(x: w * 0.44, y: h * 0.18))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// 小爱心（诚实文案旁点缀）
private struct Heart: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to: CGPoint(x: w * 0.5, y: h * 0.90))
            p.addCurve(to: CGPoint(x: w * 0.06, y: h * 0.38),
                       control1: CGPoint(x: w * 0.10, y: h * 0.62),
                       control2: CGPoint(x: w * 0.02, y: h * 0.50))
            p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.20),
                       control1: CGPoint(x: w * 0.10, y: h * 0.16),
                       control2: CGPoint(x: w * 0.34, y: h * 0.10))
            p.addCurve(to: CGPoint(x: w * 0.94, y: h * 0.38),
                       control1: CGPoint(x: w * 0.66, y: h * 0.10),
                       control2: CGPoint(x: w * 0.90, y: h * 0.16))
            p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.90),
                       control1: CGPoint(x: w * 0.98, y: h * 0.50),
                       control2: CGPoint(x: w * 0.90, y: h * 0.62))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

/// 小礼物盒（「立即更新」按钮内点缀）
private struct GiftBox: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let sw = w * 0.075
            let style = StrokeStyle(lineWidth: sw, lineCap: .round, lineJoin: .round)

            let box = Path(roundedRect: CGRect(x: w * 0.14, y: h * 0.42,
                                               width: w * 0.72, height: h * 0.46),
                           cornerRadius: w * 0.08)
            ctx.stroke(box, with: .color(color), style: style)

            let lid = Path(roundedRect: CGRect(x: w * 0.10, y: h * 0.34,
                                               width: w * 0.80, height: h * 0.14),
                           cornerRadius: w * 0.05)
            ctx.stroke(lid, with: .color(color), style: style)

            var ribbon = Path()
            ribbon.move(to: CGPoint(x: w * 0.5, y: h * 0.34))
            ribbon.addLine(to: CGPoint(x: w * 0.5, y: h * 0.88))
            ctx.stroke(ribbon, with: .color(color), style: style)

            var bowL = Path()
            bowL.move(to: CGPoint(x: w * 0.5, y: h * 0.34))
            bowL.addCurve(to: CGPoint(x: w * 0.20, y: h * 0.14),
                          control1: CGPoint(x: w * 0.30, y: h * 0.06),
                          control2: CGPoint(x: w * 0.10, y: h * 0.14))
            bowL.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.34),
                          control1: CGPoint(x: w * 0.26, y: h * 0.30),
                          control2: CGPoint(x: w * 0.40, y: h * 0.36))
            ctx.stroke(bowL, with: .color(color), style: style)

            var bowR = Path()
            bowR.move(to: CGPoint(x: w * 0.5, y: h * 0.34))
            bowR.addCurve(to: CGPoint(x: w * 0.80, y: h * 0.14),
                          control1: CGPoint(x: w * 0.70, y: h * 0.06),
                          control2: CGPoint(x: w * 0.90, y: h * 0.14))
            bowR.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.34),
                          control1: CGPoint(x: w * 0.74, y: h * 0.30),
                          control2: CGPoint(x: w * 0.60, y: h * 0.36))
            ctx.stroke(bowR, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
    }
}
