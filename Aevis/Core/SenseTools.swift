import Foundation

#if canImport(CoreLocation)
import CoreLocation
#endif

#if canImport(HealthKit)
import HealthKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// TA 的感官：知道你在哪、外面什么天、你身体怎么样。
///
/// 天气走 **Open-Meteo**：免费、不用注册、不用 API Key。
/// 这样用户不用为了问一句「今天冷不冷」再去申请一个天气接口。
extension DeviceTools {

    static var senseTools: [DeviceTool] {
        [locationTool, weatherTool, healthTool]
    }

    // MARK: - 定位

    private static var locationTool: DeviceTool {
        DeviceTool(
            name: "get_location",
            title: "看了下你在哪",
            description: """
            读取用户当前所在的位置（城市级别，不需要精确到门牌）。
            用户问「我在哪」「今天冷不冷」这类问题，或者需要按当地天气回答时用它。
            需要用户授权定位；没授权就如实说看不到。
            """,
            parameters: emptyParameters()
        ) { _ in
            #if canImport(CoreLocation)
            guard let place = await LocationReader.current() else {
                return "拿不到位置。可能是用户没授权定位（设置 → 隐私与安全性 → 定位服务 → Aevis），或者暂时定位不到。"
            }
            var lines = ["大致位置：\(place.name)"]
            if let latitude = place.latitude, let longitude = place.longitude {
                lines.append("坐标：\(String(format: "%.3f", latitude)), \(String(format: "%.3f", longitude))")
            }
            return lines.joined(separator: "\n")
            #else
            return "当前平台不支持定位。"
            #endif
        }
    }

    // MARK: - 天气

    private static var weatherTool: DeviceTool {
        DeviceTool(
            name: "get_weather",
            title: "查了天气",
            description: """
            查询用户所在地当前的天气和今天、明天的预报（温度、体感、降雨概率、风力）。
            用户问「今天冷不冷」「要带伞吗」「明天什么天」时用它。
            如果同时缺位置，先调 get_location 再调它。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "latitude": ["type": "number", "description": "纬度，可以不给，不给就用当前位置"],
                    "longitude": ["type": "number", "description": "经度，可以不给"]
                ],
                "required": [] as [String]
            ]
        ) { args in
            var latitude = args["latitude"] as? Double
            var longitude = args["longitude"] as? Double

            if latitude == nil || longitude == nil {
                #if canImport(CoreLocation)
                if let place = await LocationReader.current() {
                    latitude = place.latitude
                    longitude = place.longitude
                }
                #endif
            }

            guard let lat = latitude, let lon = longitude else {
                return "不知道你在哪，拿不到天气。先让我知道位置，或者你直接告诉我城市。"
            }

            return await WeatherReader.summary(latitude: lat, longitude: lon)
        }
    }

    // MARK: - 健康

    private static var healthTool: DeviceTool {
        DeviceTool(
            name: "get_health_summary",
            title: "看了眼你的健康数据",
            description: """
            读取健康摘要：今天的步数、最近的静息心率、昨晚的睡眠时长。
            用户问「我今天走了多少」「昨晚睡得怎么样」「我最近心率多少」时用它。
            需要用户在健康里授权；没授权就如实说看不到，并且不要追问。
            """,
            parameters: emptyParameters()
        ) { _ in
            #if canImport(HealthKit)
            return await HealthReader.summary()
            #else
            return "当前平台不支持健康数据。"
            #endif
        }
    }

    // MARK: - 零件
    // emptyParameters() 定义在 DeviceTools.swift 里，不要在这里重复声明。
}

// MARK: - 定位读取

#if canImport(CoreLocation)
struct PlaceReading {
    var name: String
    var latitude: Double?
    var longitude: Double?
}

/// 一次性的定位读取。
/// CLLocationManager 必须在主线程上创建和使用，所以整个类标了 @MainActor，
/// 调用方 await 一下就自动切到主线程。
@MainActor
final class LocationReader: NSObject, CLLocationManagerDelegate {

    static let shared = LocationReader()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<PlaceReading?, Never>?
    private var finished = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    static func current() async -> PlaceReading? {
        await shared.locate()
    }

    private func locate() async -> PlaceReading? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.finished = false

            let status = manager.authorizationStatus
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                finish(nil)
            }
        }
    }

    private func finish(_ reading: PlaceReading?) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: reading)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .notDetermined:
                break
            default:
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            Task { @MainActor in self.finish(nil) }
            return
        }
        Task { @MainActor in
            let reading = await self.describe(location)
            self.finish(reading)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    /// 只做「反查地名」，失败也不影响坐标可用。
    private func describe(_ location: CLLocation) async -> PlaceReading {
        let coordinate = location.coordinate
        var name = String(
            format: "%.2f, %.2f",
            coordinate.latitude,
            coordinate.longitude
        )

        let geocoder = CLGeocoder()
        if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
            let parts = [
                placemark.administrativeArea,
                placemark.locality,
                placemark.subLocality
            ].compactMap { $0 }
            if !parts.isEmpty {
                name = parts.joined(separator: " ")
            }
        }

        return PlaceReading(
            name: name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

// MARK: - 天气读取

/// Open-Meteo：免费、不用 Key。
enum WeatherReader {

    private static let codes: [Int: String] = [
        0: "晴", 1: "大体晴朗", 2: "局部多云", 3: "阴",
        45: "有雾", 48: "冻雾",
        51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
        56: "冻毛毛雨", 57: "强冻毛毛雨",
        61: "小雨", 63: "中雨", 65: "大雨",
        66: "冻雨", 67: "强冻雨",
        71: "小雪", 73: "中雪", 75: "大雪", 77: "雪粒",
        80: "阵雨", 81: "强阵雨", 82: "暴雨",
        85: "阵雪", 86: "强阵雪",
        95: "雷阵雨", 96: "雷阵雨伴冰雹", 99: "强雷暴伴冰雹"
    ]

    static func summary(latitude: Double, longitude: Double) async -> String {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(
                name: "current",
                value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code"
            ),
            URLQueryItem(
                name: "daily",
                value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
            ),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        guard let url = components?.url else {
            return "天气接口地址拼错了。"
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue("Aevis/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "天气返回的内容看不懂。"
            }

            var lines: [String] = []

            if let current = root["current"] as? [String: Any] {
                let code = (current["weather_code"] as? Int) ?? -1
                let temperature = (current["temperature_2m"] as? Double) ?? 0
                let feels = (current["apparent_temperature"] as? Double) ?? 0
                let humidity = (current["relative_humidity_2m"] as? Int) ?? 0
                let wind = (current["wind_speed_10m"] as? Double) ?? 0
                lines.append("现在：\(describe(code))，\(round1(temperature))°C（体感 \(round1(feels))°C）")
                lines.append("湿度 \(humidity)%，风速 \(round1(wind)) km/h")
            }

            if let daily = root["daily"] as? [String: Any],
               let dates = daily["time"] as? [String],
               let codeList = daily["weather_code"] as? [Int],
               let highs = daily["temperature_2m_max"] as? [Double],
               let lows = daily["temperature_2m_min"] as? [Double],
               let rains = daily["precipitation_probability_max"] as? [Int] {
                for index in dates.indices.prefix(2) {
                    let label = index == 0 ? "今天" : "明天"
                    lines.append(
                        "\(label)：\(describe(codeList[index]))，\(round1(lows[index]))~\(round1(highs[index]))°C，降雨 \(rains[index])%"
                    )
                }
            }

            return lines.isEmpty ? "天气返回里没有可用数据。" : lines.joined(separator: "\n")
        } catch {
            return "查天气失败了：\(error.localizedDescription)"
        }
    }

    private static func describe(_ code: Int) -> String {
        codes[code] ?? "未知天气（代码 \(code)）"
    }

    private static func round1(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
#endif

// MARK: - 健康读取

#if canImport(HealthKit)
enum HealthReader {

    private static let store = HKHealthStore()

    static func summary() async -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "这台设备上没有健康数据。"
        }

        let read: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .stepCount),
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRate),
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
        ].compactMap { $0 }.reduce(into: Set<HKObjectType>()) { $0.insert($1) }

        do {
            try await store.requestAuthorization(toShare: [], read: read)
        } catch {
            return "用户没授权健康数据，我看不到。这不是错误，不要追问。"
        }

        var lines: [String] = []

        if let steps = await stepsToday() {
            lines.append("今天走了 \(steps) 步")
        }
        if let resting = await latestQuantity(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute())) {
            lines.append("最近静息心率 \(Int(resting.rounded())) 次/分")
        }
        if let sleep = await sleepHours() {
            lines.append(String(format: "最近一次睡眠约 %.1f 小时", sleep))
        }

        return lines.isEmpty
            ? "健康里暂时没有可读的数据（也可能是权限没给全）。"
            : lines.joined(separator: "\n")
    }

    private static func stepsToday() async -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                let value = result?.sumQuantity()?.doubleValue(for: .count())
                continuation.resume(returning: value.map { Int($0) })
            }
            store.execute(query)
        }
    }

    private static func latestQuantity(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: nil,
                limit: 1,
                sortDescriptors: sort
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// 最近 24 小时里睡着的那部分时长。
    private static func sleepHours() async -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let start = Date().addingTimeInterval(-24 * 3600)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                let total = (samples as? [HKCategorySample])?
                    .filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) } ?? 0
                continuation.resume(returning: total > 0 ? total / 3600.0 : nil)
            }
            store.execute(query)
        }
    }
}
#endif
