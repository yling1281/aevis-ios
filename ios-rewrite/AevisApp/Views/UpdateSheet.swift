import SwiftUI

/// 磨砂玻璃风格的半屏更新弹窗：强制模式关不掉、进不去；可选模式可「以后再说」。
///
/// 视觉（2026-11-22 重做，照用户给的「忆伴」更新弹窗参考图）：
/// 左对齐「自家狗 logo + 标题 + 版本行」→ 一张磨砂说明卡（顶部【更新内容】小标题 +
/// 正文，行距 6，内容多可滚）→ 小灰字安装提示 → 底部深藏青实心大按钮「确定」。
/// 层次靠材质与透明度区分，不靠边框；深色模式材质与文字语义色自适应。
///
/// 行为完全保留：
/// - 半屏由外层 `.sheet` 的 `.presentationDetents([.medium])` 决定（见 `AevisApp.swift`）；
/// - 强制模式 `.interactiveDismissDisabled(true)`，且外层 Binding set 被忽略；
/// - 点「确定」走 `center.openInstall()`（OTA / ipa），文案诚实说明 iOS 安装限制。
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
                    VStack(alignment: .leading, spacing: 14) {
                        // MARK: 头部：logo + 「Aevis X.X 更新」+ 版本行（参考图左对齐版式）
                        HStack(alignment: .center, spacing: 12) {
                            AevisMascot(size: 46)
                                .shadow(color: AE.shadowColor, radius: 6, y: 2)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Aevis \(info.latest) 更新")
                                    .font(.system(size: 19, weight: .bold, design: .rounded))
                                    .foregroundStyle(ink)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)

                                Text(info.force
                                     ? "当前版本已停止支持"
                                     : "当前 \(info.current) · 最新 \(info.latest)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(AE.textSecondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 2)

                        // 强制更新必须写清「下一步」（2026-11-25）。
                        // 只写「需要更新后才能继续使用」的话，用户点开发现关不掉、
                        // 又不知道要去哪、装完要干什么，第一反应是「App 坏了」。
                        // 这个 App 从来都是未签名 IPA + 全能签安装，所以「下载 IPA 再签名」
                        // 就是它唯一的常规升级路径，如实写出来即可。
                        if info.force {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("安装包已就绪（\(info.latest)）")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(ink)

                                nextStep("1", info.hasOTA
                                         ? "点下方按钮跳转系统安装页"
                                         : "点下方按钮下载 IPA（会存到「文件」里）")
                                nextStep("2", info.hasOTA
                                         ? "按系统提示完成安装"
                                         : "用签名工具（全能签等）对它签名安装")
                                nextStep("3", "装好后重新打开 App 即可继续使用")
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard(cornerRadius: 16, material: .thin, tintOpacity: 0.16)
                        }

                        // MARK: 正文：一张磨砂卡，顶部小标题 + 说明正文
                        VStack(alignment: .leading, spacing: 10) {
                            Text("【更新内容】")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ink)

                            if info.notes.isEmpty {
                                Text("本次更新包含稳定性改进与问题修复。")
                                    .font(.system(size: 14))
                                    .lineSpacing(6)
                                    .foregroundStyle(AE.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ScrollView(showsIndicators: false) {
                                    Text(info.notes)
                                        .font(.system(size: 14))
                                        .lineSpacing(6.5)
                                        .foregroundStyle(AE.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 168)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 18, material: .thin, tintOpacity: 0.20)

                        // MARK: 底部小灰字安装提示（小爱心弱化点缀）
                        // 强制更新时上面已经写了分步指引，这里不再重复一遍；
                        // 非强制更新保留，讲清「点了会发生什么」。
                        if !info.force {
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
                        }

                        // MARK: 主按钮：深藏青实心大按钮
                        // 强制 + 手动装包时按钮直接叫「下载 IPA」——「确定」不知道确定什么。
                        Button { center.openInstall() } label: {
                            Text(mainButtonTitle)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(AE.accentDeep, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: AE.accentDeep.opacity(0.28), radius: 10, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)

                        // 非强制更新保留一条低调的退出路径（强制更新必须更新完才能继续）
                        if !info.force {
                            Button { center.dismiss() } label: {
                                Text("以后再说")
                                    .font(.system(size: 13))
                                    .foregroundStyle(AE.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 34)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .interactiveDismissDisabled(info.force)
        }
    }

    /// 主按钮文案。
    /// 强制 + 手动装包时叫「下载 IPA」——「确定」两个字在这里没有信息量；
    /// OTA 走系统安装页，叫「去更新」；非强制保留原来的「确定」。
    private var mainButtonTitle: String {
        guard let info = center.latest, info.force else { return "确定" }
        return info.hasOTA ? "去更新" : "下载 IPA"
    }

    /// 强制更新的分步指引行：序号圆点 + 说明。
    private func nextStep(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(ink, in: Circle())
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(AE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
