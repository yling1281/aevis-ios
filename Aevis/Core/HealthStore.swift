import Foundation
import HealthKit

/// 苹果健康（2026-10-31 新增）。
///
/// 把经期记录写进健康 App（月经流血量样本），也能回读，用来做简单预测。
/// 同时能读步数 / 心率 / 睡眠（App 早就有 `NSHealthShareUsageDescription` 了）。
///
/// ⚠️ 必须在 `Aevis.entitlements` 里有 `com.apple.developer.healthkit`，
///    并开启 App ID 的 HealthKit 能力。没授权时读写都会温柔失败，不会崩。
@MainActor
final class HealthStore: ObservableObject {
    static let shared = HealthStore()

    private let store = HKHealthStore()

    @Published private(set) var authorized = false
    @Published private(set) var periodDays: [Date] = []
    @Published private(set) var lastError: String?

    private let menstrual = HKObjectType.categoryType(forIdentifier: .menstrualFlow)!
    private let stepCount = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    private init() {}

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "这台设备不支持健康（模拟器或非 iPhone）。"
            return
        }
        let read: Set<HKObjectType> = [menstrual, stepCount, heartRate, sleep]
        let share: Set<HKSampleType> = [menstrual]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            authorized = store.authorizationStatus(for: menstrual) != .notDetermined
            await loadPeriodDays()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 记某天为经期（默认今天）。只标一天；想标连续几天就多次调用。
    func logPeriod(on date: Date = Date()) async {
        let sample = HKCategorySample(
            type: menstrual,
            value: HKCategoryValueMenstrualFlow.unspecified.rawValue,
            start: date,
            end: date
        )
        do {
            try await store.save(sample)
            await loadPeriodDays()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadPeriodDays() async {
        guard isAvailable else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: menstrual,
            predicate: nil,
            limit: 200,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.lastError = error.localizedDescription }
                return
            }
            let days = (samples as? [HKCategorySample])?.map { $0.startDate } ?? []
            Task { @MainActor in self.periodDays = days }
        }
        store.execute(query)
    }

    /// 极简预测：取最近两次经期开始的间隔估一个周期，推下一次。
    var nextPeriodPrediction: Date? {
        guard periodDays.count >= 2 else { return nil }
        let sorted = periodDays.sorted()
        let last = sorted.last!
        let prev = sorted[sorted.count - 2]
        let cycle = last.timeIntervalSince(prev) / 86400.0
        guard cycle > 10, cycle < 60 else { return nil }
        return last.addingTimeInterval(cycle * 86400.0)
    }
}
