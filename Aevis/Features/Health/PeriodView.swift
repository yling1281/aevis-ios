import SwiftUI

/// 健康（2026-10-31）。
///
/// 用户原话：「经期点进去的话，应该是你所有的一些数据，就是你的一些跑步啊、
/// 走路呀、心率之类的，不只是经期。然后你点一下记录就会闪退，这个要弄一下。」
///
/// 所以这一页现在是**健康总览**，经期只是其中一块：
/// 1. 今日概览：步数 / 距离 / 活动能量 / 心率 / 昨晚睡眠
/// 2. 最近运动：跑步、走路、骑行…（最近 7 天）
/// 3. 经期：记录、预测、最近记录
///
/// ⚠️ 名字还叫 `PeriodView` 是为了不动 `MeView` 里的引用 —— 它已经不是"经期页"了。
struct PeriodView: View {
    @ObservedObject private var health = HealthStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !health.isAvailable {
                        unavailableCard
                    } else if !health.authorized {
                        authCard
                    } else {
                        todayCard
                        workoutCard
                    }

                    periodCard

                    if let error = health.lastError {
                        Text(error)
                            .font(.aevis(12))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("健康")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await health.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.aevis(14, weight: .medium))
                    }
                    .disabled(health.loading)
                }
            }
            // ⚠️ 只在还没授权时请求一次 —— 每次进页面都请求会一直弹系统框。
            .task {
                if !health.authorized { await health.requestAuthorization() }
            }
        }
    }

    // MARK: - 不支持 / 未授权

    private var unavailableCard: some View {
        card {
            // 2026-11-12：不能一律写"设备不支持"。自签包最常见的原因是
            // **签名里没带 HealthKit 权限**，跟设备无关 —— 文案说错了会让人白折腾。
            if health.availability == .noEntitlement {
                Text("这个安装包没有健康权限")
                    .font(.aevis(15, weight: .medium))
                Text("签名用的描述文件里没带 HealthKit。经期照常记在这台手机上；换一个带健康权限的包之后，会自动同步进健康 App。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("这台设备不支持健康数据")
                    .font(.aevis(15, weight: .medium))
                Text("模拟器或非 iPhone 上读不到健康。经期记录仍然可以记在这台设备上。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var authCard: some View {
        card {
            Text("连接苹果健康")
                .font(.aevis(15, weight: .medium))
            Text("授权后能看到步数、跑步走路、心率和睡眠；经期记录写进健康 App。数据不出这台手机。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await health.requestAuthorization() }
            } label: {
                Text("授权健康")
                    .font(.aevis(14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
            }
        }
    }

    // MARK: - 今日概览

    private var todayCard: some View {
        card {
            HStack {
                Text("今天")
                    .font(.aevis(13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if health.loading {
                    ProgressView().controlSize(.mini)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                metric("步数", "figure.walk", value: "\(health.stepsToday)", unit: "步")
                metric("距离", "location", value: String(format: "%.2f", health.distanceToday), unit: "公里")
                metric("活动", "flame", value: "\(Int(health.activeEnergy.rounded()))", unit: "千卡")
                metric("心率", "heart", value: health.latestHeartRate > 0
                       ? "\(Int(health.latestHeartRate.rounded()))" : "—", unit: "次/分")
                metric("静息心率", "waveform.path.ecg", value: health.restingHeartRate > 0
                       ? "\(Int(health.restingHeartRate.rounded()))" : "—", unit: "次/分")
                metric("昨晚睡眠", "bed.double", value: health.sleepHours > 0
                       ? String(format: "%.1f", health.sleepHours) : "—", unit: "小时")
            }
        }
    }

    private func metric(_ title: String, _ symbol: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.aevis(11.5, weight: .medium))
                Text(title)
                    .font(.aevis(11.5))
            }
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.aevis(20, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.aevis(10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - 最近运动

    private var workoutCard: some View {
        card {
            Text("最近运动")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.secondary)

            if health.workouts.isEmpty {
                Text("最近 7 天没有运动记录。")
                    .font(.aevis(13))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(health.workouts) { w in
                    HStack(spacing: 10) {
                        Image(systemName: w.symbol)
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(AppSettings.shared.accentColor)
                            .frame(width: 26)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.title)
                                .font(.aevis(14, weight: .medium))
                            Text(w.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.aevis(11))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 6)

                        VStack(alignment: .trailing, spacing: 2) {
                            if w.distance > 0 {
                                Text(String(format: "%.2f 公里", w.distance))
                                    .font(.aevis(13, weight: .medium))
                            }
                            Text("\(Int(w.duration / 60)) 分钟")
                                .font(.aevis(11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - 经期

    private var periodCard: some View {
        card {
            Text("经期")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                // ⚠️ 这个按钮以前会闪退 —— 根因和修法都在 `HealthStore` 的类注释里
                //    （零长度样本 / 没权限硬写 / 同一天重复写，三样都会崩）。
                Task { await health.logPeriod() }
            } label: {
                Label("标记今天为经期", systemImage: "drop.fill")
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aevisGlass(cornerRadius: 14)
            }
            .buttonStyle(.plain)

            if let next = health.nextPeriodPrediction {
                HStack(spacing: 6) {
                    Text("下一次大概")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    Text(next, style: .date)
                        .font(.aevis(14, weight: .semibold))
                    Spacer(minLength: 0)
                }
            } else if health.periodDays.count < 2 {
                Text("记两次之后才会预测下一次。")
                    .font(.aevis(12))
                    .foregroundStyle(.tertiary)
            }

            if health.periodDays.isEmpty {
                Text("还没有记录。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.tertiary)
            } else {
                Divider().padding(.vertical, 2)
                // ⚠️ 不能用 `id: \.self` —— 日期重复时 id 撞车，SwiftUI 会崩。
                ForEach(Array(health.periodDays.prefix(12).enumerated()), id: \.offset) { _, day in
                    Text(day.formatted(date: .abbreviated, time: .omitted))
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 卡片壳

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aevisGlass(cornerRadius: 20)
    }
}
