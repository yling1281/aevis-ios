import SwiftUI

/// 磨砂玻璃风格的半屏更新弹窗：强制模式关不掉、进不去；可选模式可「稍后」。
///
/// 视觉（2026-11-24 重做，照用户参考图）：整个弹窗磨砂玻璃、居中简笔猫脸 logo、
/// 深藏青标题「新版本 X.X」、半透明磨砂说明卡、小灰字安装提示、深藏青实心胶囊主按钮。
/// 层次靠材质与透明度区分，不靠边框；深色模式材质与文字语义色自适应。
///
/// 行为完全保留：
/// - 半屏由外层 `.sheet` 的 `.presentationDetents([.medium])` 决定（见 `AevisApp.swift`）；
/// - 强制模式不显示「稍后」+ `.interactiveDismissDisabled(true)`，外层 Binding set 也被忽略；
/// - 点「立即更新」走 `center.openInstall()`（OTA / ipa），文案诚实说明 iOS 安装限制。
struct UpdateSheet: View {
    @ObservedObject var center: AppUpdateCenter

    /// 深藏青主色（参考图 #2F3A56）；浅色模式用自适应 AE.accent 保证深色模式可读。
    private var ink: Color { AE.accent }

    var body: some View {
        if let info = center.latest {
            ZStack {
                // 磨砂玻璃背板：让背后的聊天界面透出模糊感（外层 sheet 已设 presentationBackground(.clear)）
                GlassBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 13) {
                        // MARK: 居中使用自家官网 logo（矢量狗，奶油底 + 柔紫光晕），与登录页同一只
                        AevisMascot(size: 72)
                            .padding(.top, 2)

                        // MARK: 标题「新版本 X.X」——主视觉，深藏青粗体居中
                        Text("新版本 \(info.latest)")
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                            .multilineTextAlignment(.center)

                        // 强制 / 可选只用小字区分，不再用橙色警告三角当主视觉
                        Text(info.force ? "需要更新后才能继续使用" : "有新版本可用")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AE.textSecondary)

                        Text("当前 \(info.current) · 最新 \(info.latest)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AE.textSecondary.opacity(0.85))

                        // MARK: 更新说明——半透明白色磨砂卡片，深蓝灰字，行距舒服，内容多可滚
                        if !info.notes.isEmpty {
                            ScrollView(showsIndicators: false) {
                                Text(info.notes)
                                    .font(.system(size: 14))
                                    .lineSpacing(6)
                                    .foregroundStyle(ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                            .frame(maxHeight: 140)
                            .glassCard(cornerRadius: 16)
                            .padding(.top, 2)
                        }

                        // MARK: 底部小灰字安装提示（小爱心弱化点缀）
                        HStack(alignment: .top, spacing: 5) {
                            Heart(color: AE.textSecondary.opacity(0.5), size: 12)
                                .padding(.top, 2)
                            Text(info.hasOTA
                                 ? "将跳转到系统安装页完成更新。"
                                 : "将下载安装包（.ipa）。iOS 不允许 App 自行安装，下载后请在「文件」中用签名工具安装。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(AE.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 1)

                        // MARK: 操作按钮——主按钮深藏青实心胶囊；「稍后」低调幽灵样式
                        HStack(spacing: 10) {
                            if !info.force {
                                Button { center.dismiss() } label: {
                                    Text("稍后")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(ink)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 50)
                                        .glassCard(cornerRadius: 25, material: .thin,
                                                   tintOpacity: 0.08, strokeOpacity: 0.18)
                                }
                                .buttonStyle(.plain)
                            }

                            Button { center.openInstall() } label: {
                                Text("立即更新")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 50)
                                    .background(AE.accentDeep, in: Capsule())
                                    .shadow(color: AE.accentDeep.opacity(0.28), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 6)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
            }
            .interactiveDismissDisabled(info.force)
        }
    }
}

// MARK: - 自绘矢量（私有，仅本文件可见；全部 Canvas + Path，归一化 0~1 坐标）

/// 小爱心（安装提示旁点缀，弱化）
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
