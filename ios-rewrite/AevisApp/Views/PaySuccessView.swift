import SwiftUI

/// 支付成功动效（第 3 轮）：一笔勾 + spring 弹跳 + 到账数字滚动 + 「我已完成」关闭刷新。
///
/// 由商城在查单确认 `state == paid` 后以 `.sheet` 弹出（透明背景 + 磨砂背板）。
/// 动效时序：进场 scale 0.6→1.0（spring damping 0.6）→ 0.12s 后勾从 0→1 一笔画出（0.5s ease）→ 数字滚动。
/// 到账数字用 `AnimatedNumber`；金额与单位由调用方给（墨点 = N 墨点，会员 = N 天会员）。
/// `onDone` 由调用方关闭弹层并刷新余额 / 会员状态；本视图不自行改数据，保持单一职责。
struct PaySuccessView: View {
    @Environment(\.dismiss) private var dismiss

    /// 主标题（「支付成功」）
    var title: String = "支付成功"
    /// 到账数字（墨点数 / 会员天数）
    let amount: Int
    /// 单位（「墨点」/「天会员」）
    let unit: String
    /// 副标题说明（「余额已更新」/「会员已续期」）
    var subtitle: String = "已到账，可在账号中查看"
    /// 完成回调：关闭 + 刷新由调用方处理
    var onDone: (() -> Void)? = nil

    @State private var appeared = false      // 控制缩放弹跳
    @State private var checkProgress: CGFloat = 0   // 勾的一笔画进度 0→1
    @State private var glow = false          // 勾完成后的一圈脉冲

    var body: some View {
        ZStack {
            GlassBackdrop()

            VStack(spacing: 18) {
                // 勾：外圈脉冲 + 一笔路径
                ZStack {
                    if glow {
                        Circle()
                            .stroke(AE.brandPurple.opacity(0.35), lineWidth: 2)
                            .frame(width: 108, height: 108)
                            .scaleEffect(glow ? 1.18 : 0.9)
                            .opacity(glow ? 0 : 1)
                            .animation(.easeOut(duration: 0.7), value: glow)
                    }

                    Circle()
                        .fill(AE.brandPurple.opacity(0.14))
                        .frame(width: 92, height: 92)

                    CheckmarkShape()
                        .trim(from: 0, to: checkProgress)
                        .stroke(
                            LinearGradient(
                                colors: [AE.brandPurple, AE.accentDeep],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: 52, height: 52)
                }
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)

                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.accentDeep)

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("+")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(AE.brandPurple)
                        AnimatedNumber(
                            value: amount,
                            font: .system(size: 34, weight: .bold, design: .rounded),
                            color: AE.accentDeep
                        )
                        Text(unit)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AE.textSecondary)
                    }

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

                Button {
                    onDone?()
                    dismiss()
                } label: {
                    Text("我已完成")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(AE.accentDeep, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .opacity(appeared ? 1 : 0)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: AE.sheetRadius, material: .regular, tintOpacity: 0.5)
            .padding(.horizontal, 24)
            .scaleEffect(appeared ? 1 : 0.92)
        }
        .onAppear { play() }
    }

    private func play() {
        // 卡片 spring 弹跳进场
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            appeared = true
        }
        // 勾：0.12s 后开始一笔画（0.5s），完成后触发一次脉冲
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.5)) {
                checkProgress = 1
            }
            try? await Task.sleep(nanoseconds: 520_000_000)
            glow = true
        }
    }
}

/// 一笔画的对勾路径（左下 → 折点 → 右上）。normalize 到 0...1 坐标系便于缩放。
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let a = CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.52)
        let b = CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.84)
        let c = CGPoint(x: rect.minX + rect.width * 0.96, y: rect.minY + rect.height * 0.16)
        p.move(to: a)
        p.addLine(to: b)
        p.addLine(to: c)
        return p
    }
}
