import SwiftUI

/// 经期 / 健康（2026-10-31）。
///
/// 在这里记「今天来姨妈了」，数据写进健康 App（经期流血量样本）；
/// 后面能看到最近记录了哪几天、下一次大概什么时候。
struct PeriodView: View {
    @ObservedObject private var health = HealthStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !health.isAvailable {
                        Text("这台设备不支持健康（模拟器或非 iPhone）。记录会在真机上出现。")
                            .font(.aevis(13))
                            .foregroundStyle(.secondary)
                    } else if !health.authorized {
                        authCard
                    } else {
                        logCard
                        predictionCard
                        historyCard
                    }

                    if let error = health.lastError {
                        Text(error)
                            .font(.aevis(12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("经期 / 健康")
            .navigationBarTitleDisplayMode(.inline)
            .task { await health.requestAuthorization() }
        }
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("连接苹果健康")
                .font(.aevis(15, weight: .medium))
            Text("授权后，经期记录会写进健康 App，也能从这里回看。数据不出这台手机。")
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
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("记录")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.secondary)
            Button {
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
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var predictionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下一次预测")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.secondary)
            if let next = health.nextPeriodPrediction {
                Text(next, style: .date)
                    .font(.aevis(16, weight: .semibold))
            } else {
                Text("记录两次经期后才会预测。")
                    .font(.aevis(13))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近记录")
                .font(.aevis(13, weight: .medium))
                .foregroundStyle(.secondary)
            if health.periodDays.isEmpty {
                Text("还没有记录。")
                    .font(.aevis(13))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(health.periodDays.prefix(20), id: \.self) { day in
                    Text(day, style: .date)
                        .font(.aevis(14))
                }
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }
}
