import Foundation
import HealthKit

/// 苹果健康（2026-10-31 新增，2026-10-31 晚扩充）。
///
/// 原来只管经期，现在**这一页是"全部健康数据"**：
/// 今天的步数 / 跑步走路距离 / 心率 / 昨晚睡眠 / 最近的运动记录，
/// 外加经期记录与预测。
///
/// ## 🔴 为什么「点记录会闪退」（已修）
/// 三个可能让人闪退的地方，全部在这里堵掉：
///
/// 1. **等长样本**：老代码 `start: date, end: date` —— 零长度。
///    HealthKit 对分类样本要求 `start < end`，不满足时它抛的是
///    **OC 异常（NSInvalidArgumentException）**，Swift 的 `do/catch` **接不住**，
///    进程直接死。现在统一给 1 分钟窗口。
/// 2. **没权限也去写**：没有 share 授权时 `save` 同样可能抛 OC 异常。
///    现在先看 `authorizationStatus(for:)`，不是 `.sharingAuthorized` 就走本地兜底，
///    **根本不去碰 HealthKit**。
/// 3. **同一天重复写**：用户连点两下就是两条样本，`ForEach(id: \.self)` 撞 id
///    也会让 SwiftUI 崩。现在当天已有样本就跳过，并且本地记录按"天"去重。
///
/// ⚠️ 必须在 `Aevis.entitlements` 里有 `com.apple.developer.healthkit`，
///    并开启 App ID 的 HealthKit 能力。没授权时读写都会温柔失败，不会崩。
@MainActor
final class HealthStore: ObservableObject {
    static let shared = HealthStore()

    private let store = HKHealthStore()

    @Published private(set) var authorized = false
    /// 健康 App 里的经期记录。
    @Published private(set) var periodDays: [Date] = []
    /// 本地兜底记录（健康写不进去时，至少这一页还显示得出来）。
    @Published private(set) var localPeriodDays: [Date] = []
    @Published private(set) var lastError: String?

    // 今天 / 最近的数据
    @Published private(set) var stepsToday: Int = 0
    @Published private(set) var distanceToday: Double = 0        // 公里
    @Published private(set) var activeEnergy: Double = 0          // 千卡
    @Published private(set) var latestHeartRate: Double = 0       // 次/分
    @Published private(set) var restingHeartRate: Double = 0      // 次/分
    @Published private(set) var sleepHours: Double = 0
    @Published private(set) var workouts: [HealthWorkout] = []
    @Published private(set) var loading = false

    /// 一条运动记录（跑步 / 走路 / 骑行…）。
    struct HealthWorkout: Identifiable, Hashable {
        var id: String
        var title: String
        var symbol: String
        var start: Date
        var duration: Double      // 秒
        var distance: Double      // 公里（没有就是 0）
        var energy: Double        // 千卡
    }

    private let menstrual = HKObjectType.categoryType(forIdentifier: .menstrualFlow)!
    private let stepCount = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let restingHR = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
    private let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
    private let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!

    private let localKey = "aevis.health.period.local"

    private init() {
        localPeriodDays = Self.loadLocal(key: localKey)
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - 授权

    func requestAuthorization() async {
        guard isAvailable else {
            lastError = "这台设备不支持健康（模拟器或非 iPhone）。"
            return
        }
        let read: Set<HKObjectType> = [
            menstrual, stepCount, heartRate, restingHR, sleep, distanceType, energyType,
            HKObjectType.workoutType()
        ]
        let share: Set<HKSampleType> = [menstrual]
        do {
            try await store.requestAuthorization(toShare: share, read: read)
            // ⚠️ 读权限是**问不出来**的（苹果故意的，防推断）。所以这里只判写权限；
            //    读不到数据时各查询自己回 0，不把 authorized 判成 false 卡在授权页。
            authorized = true
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 一次拉全

    func refresh() async {
        guard isAvailable else { return }
        loading = true
        defer { loading = false }

        async let steps = sum(.stepCount, unit: .count())
        async let dist = sum(.distanceWalkingRunning, unit: .meterUnit(with: .kilo))
        async let energy = sum(.activeEnergyBurned, unit: .kilocalorie())
        async let hr = latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let rest = latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()))
        async let slept = sleepLastNight()

        stepsToday = Int((await steps) ?? 0)
        distanceToday = (await dist) ?? 0
        activeEnergy = (await energy) ?? 0
        latestHeartRate = (await hr) ?? 0
        restingHeartRate = (await rest) ?? 0
        sleepHours = (await slept) ?? 0

        await loadPeriodDays()
        await loadWorkouts()
    }

    // MARK: - 经期

    /// 记某天为经期（默认今天）。
    ///
    /// 三道保险，见类注释里的「为什么会闪退」。
    func logPeriod(on date: Date = Date()) async {
        let day = Calendar.current.startOfDay(for: date)

        // ③ 当天已经记过就别再写一遍（连点两下 → 两条样本 → 列表撞 id）
        if periodDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) {
            lastError = "今天已经记过了。"
            return
        }

        // ② 没有写权限就**不碰 HealthKit**（没权限时它抛的是 OC 异常，接不住）
        let canWrite = isAvailable && store.authorizationStatus(for: menstrual) == .sharingAuthorized
        if canWrite {
            // ① 给 1 分钟窗口 —— 零长度样本会抛 OC 异常，do/catch 接不住
            let sample = HKCategorySample(
                type: menstrual,
                value: HKCategoryValueMenstrualFlow.unspecified.rawValue,
                start: day,
                end: day.addingTimeInterval(60)
            )
            do {
                try await store.save(sample)
                lastError = nil
            } catch {
                // 这里能接住的只是 Swift 层的错误（权限 / 数据库），记下来继续走本地兜底
                lastError = "写进健康 App 失败（\(error.localizedDescription)），已记在 App 里。"
            }
        } else {
            lastError = "还没给「写入经期」的权限，先记在 App 里。"
        }

        // 本地兜底：不管健康写没写成功，这一页都看得见
        if !localPeriodDays.contains(where: { Calendar.current.isDate($0, inSameDayAs: day) }) {
            localPeriodDays.append(day)
            localPeriodDays.sort(by: >)
            Self.saveLocal(localPeriodDays, key: localKey)
        }

        await loadPeriodDays()
    }

    func loadPeriodDays() async {
        guard isAvailable else {
            periodDays = localPeriodDays
            return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: menstrual,
            predicate: nil,
            limit: 400,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.lastError = error.localizedDescription }
                return
            }
            let days = (samples as? [HKCategorySample])?.map { $0.startDate } ?? []
            Task { @MainActor in self.applyHealthDays(days) }
        }
        store.execute(query)
    }

    /// 健康里的记录 + 本地兜底，按"天"去重后合并。
    private func applyHealthDays(_ days: [Date]) {
        var seen = Set<Date>()
        var merged: [Date] = []
        for d in (days + localPeriodDays).sorted(by: >) {
            let key = Calendar.current.startOfDay(for: d)
            if seen.insert(key).inserted { merged.append(key) }
        }
        periodDays = merged
    }

    /// 极简预测：取最近两次经期开始的间隔估一个周期，推下一次。
    var nextPeriodPrediction: Date? {
        guard periodDays.count >= 2 else { return nil }
        let sorted = periodDays.sorted()
        let last = sorted[sorted.count - 1]
        let prev = sorted[sorted.count - 2]
        let cycle = last.timeIntervalSince(prev) / 86400.0
        guard cycle > 10, cycle < 60 else { return nil }
        return last.addingTimeInterval(cycle * 86400.0)
    }

    // MARK: - 查询

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let q = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        return await withCheckedContinuation { continuation in
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: sort) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// 昨晚那一段睡着的时间（最近 24 小时内的 asleep 样本求和）。
    private func sleepLastNight() async -> Double? {
        let start = Date().addingTimeInterval(-24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]
        return await withCheckedContinuation { continuation in
            let q = HKSampleQuery(
                sampleType: sleep,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let total = (samples as? [HKCategorySample])?
                    .filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } ?? 0
                continuation.resume(returning: total > 0 ? total / 3600.0 : nil)
            }
            store.execute(q)
        }
    }

    /// 最近 7 天的运动（跑步 / 走路 / 骑行…）。
    private func loadWorkouts() async {
        let start = Date().addingTimeInterval(-7 * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]

        let list: [HealthWorkout] = await withCheckedContinuation { continuation in
            let q = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: 20,
                sortDescriptors: sort
            ) { _, samples, _ in
                let rows = (samples as? [HKWorkout])?.map { w -> HealthWorkout in
                    let km = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)) ?? 0
                    let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
                    let (title, symbol) = Self.describe(w.workoutActivityType)
                    return HealthWorkout(
                        // 用 uuid —— 同一天跑两次也不会撞 id
                        id: w.uuid.uuidString,
                        title: title,
                        symbol: symbol,
                        start: w.startDate,
                        duration: w.duration,
                        distance: km,
                        energy: kcal
                    )
                } ?? []
                continuation.resume(returning: rows)
            }
            store.execute(q)
        }
        workouts = list
    }

    private static func describe(_ type: HKWorkoutActivityType) -> (String, String) {
        switch type {
        case .running: return ("跑步", "figure.run")
        case .walking: return ("走路", "figure.walk")
        case .cycling: return ("骑行", "figure.outdoor.cycle")
        case .swimming: return ("游泳", "figure.pool.swim")
        case .hiking: return ("徒步", "figure.hiking")
        case .yoga: return ("瑜伽", "figure.yoga")
        case .functionalStrengthTraining, .traditionalStrengthTraining:
            return ("力量训练", "figure.strengthtraining.traditional")
        case .highIntensityIntervalTraining: return ("HIIT", "figure.highintensity.intervaltraining")
        case .jumpRope: return ("跳绳", "figure.jumprope")
        case .dance: return ("跳舞", "figure.dance")
        default: return ("运动", "figure.mixed.cardio")
        }
    }

    // MARK: - 本地兜底存储

    private static func loadLocal(key: String) -> [Date] {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [Double] else { return [] }
        return raw.map { Date(timeIntervalSince1970: $0) }
    }

    private static func saveLocal(_ days: [Date], key: String) {
        UserDefaults.standard.set(days.map { $0.timeIntervalSince1970 }, forKey: key)
    }
}
