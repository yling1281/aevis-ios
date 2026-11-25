import SwiftUI

/// 每日签到（2.8 重做视觉）：真实接口 `/v1/checkin/status` + `POST /v1/checkin`。
/// 取不到状态就显示「暂无数据」，不编造连续天数 / 奖励数字。
/// 数值全部走 `AnimatedNumber`（逐帧滚动），卡片 `staggerIn` 轻微上浮入场 + 柔和阴影。
struct CheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    @State private var status: GrowthAPI.CheckInStatus? = nil
    @State private var tip = ""
    @State private var busy = false
    @State private var celebrating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("每日签到").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    hero.staggerIn(0)
                    statRow.staggerIn(1)
                    rules.staggerIn(2)
                }
                .padding(18)
                .padding(.bottom, 30)
            }
            .background(Color.clear)

            if !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .background(AppBackground())
        .appBackgroundIntensity(AEGlass.veilDefault)
        .task { await load() }
    }

    // MARK: - 主卡

    private var hero: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AE.brandPurple.opacity(0.16))
                    .frame(width: 86, height: 86)
                Image(systemName: celebrating ? "sparkles" : "calendar.badge.plus")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AE.brandPurple)
                    .scaleEffect(celebrating ? 1.12 : 1.0)
                    .animation(AEMotion.riseAnimation, value: celebrating)
            }
            .accessibilityHidden(true)

            if let s = status {
                HStack(spacing: 6) {
                    Text(s.done ? "今天已签到" : "今天可签到")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                    if s.memberBoost {
                        Text("会员 ×\(s.multiplier)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AE.memberBadge, in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text("下次可得")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                    AnimatedNumber(
                        value: s.nextReward,
                        font: .system(size: 22, weight: .heavy, design: .rounded),
                        color: AE.brandPurple
                    )
                    Text("墨点")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                }

                Button {
                    Task { await checkin() }
                } label: {
                    Text(buttonTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(
                            (status?.done == true) ? AE.accentSoft : AE.brandPurple,
                            in: Capsule()
                        )
                }
                .buttonStyle(AevisPressStyle(scale: 0.97))
                .disabled(status?.done == true || busy)
                .padding(.top, 4)
            } else {
                Text("暂无数据").font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                Button { Task { await load() } } label: {
                    Text("重新加载").font(.system(size: 12, weight: .medium)).foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .glassCard(cornerRadius: AEGlass.cardRadius, material: .regular, tintOpacity: 0.22)
        .shadow(color: AE.shadowColor, radius: 16, y: 7)
    }

    private var buttonTitle: String {
        if busy { return "签到中…" }
        return status?.done == true ? "今天已签到" : "立即签到"
    }

    // MARK: - 三个数字

    private var statRow: some View {
        HStack(spacing: 10) {
            statCard(title: "本月签到", value: status?.monthCount ?? 0, icon: "calendar", index: 0)
            statCard(title: "连续天数", value: status?.streak ?? 0, icon: "flame.fill", index: 1)
            statCard(title: "累计墨点", value: status?.totalPoints ?? 0, icon: "sparkles", index: 2)
        }
    }

    private func statCard(title: String, value: Int, icon: String, index: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.accent)
            if status == nil {
                Text("—").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(AE.textSecondary)
            } else {
                AnimatedNumber(
                    value: value,
                    font: .system(size: 19, weight: .heavy, design: .rounded),
                    color: AE.textPrimary
                )
            }
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(AE.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin, tintOpacity: 0.16)
        .shadow(color: AE.shadowColor, radius: 10, y: 4)
        .staggerIn(index + 1)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("签到规则")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AE.textPrimary)
            Text("每天固定 20 墨点，会员翻倍到 40。连续天数只用于统计，断签后从 1 天重新计算。")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin, tintOpacity: 0.14)
    }

    // MARK: - 数据

    private func load() async {
        guard let token = session.token, !token.isEmpty else {
            await MainActor.run { status = nil }
            return
        }
        let fresh = await GrowthAPI.checkinStatus(token: token)
        await MainActor.run { status = fresh }
    }

    private func checkin() async {
        guard let token = session.token, !token.isEmpty else { return }
        await MainActor.run { busy = true }
        let result = await GrowthAPI.doCheckin(token: token)
        await MainActor.run {
            busy = false
            guard let result else {
                showTip("签到失败，请稍后再试")
                return
            }
            if result.already {
                showTip("今天已经签过了")
            } else {
                showTip("签到成功，获得 \(result.points) 墨点")
                celebrating = true
                withAnimation(AEMotion.riseAnimation.delay(0.6)) { celebrating = false }
            }
        }
        await load()
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
