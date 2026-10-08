import CoreLocation
import Darwin
import Foundation
import Network
import NetworkExtension
import UIKit

/// 读「这台机器」的几样东西，组装成一份快照。
///
/// 每一样都**各自容错**：任何一项拿不到都不影响其它项，也绝不让整次采集失败。
/// 拿不到的项在快照里就是 `has… = false` / 空串，上报那一刻**直接不写那个键**
/// （契约要求「缺项就别发」，不写 `null`、也不写空串）。
///
/// ⚠️ 屏幕使用时间**明确不做**：App 侧读不到别家 App 的使用时长，
///    要拿它必须申请 Family Controls（家长控制）权限、还要一个专门的能力授权 ——
///    这正是本项目「不许加 entitlements」的红线之内不能碰的东西。
///    所以这里**不硬编一个假数字**，干脆不报这一项。
///
/// ⚠️ 步数**同样不做**（2026-10-09 决定）：读步数只能走 HealthKit，
///    而 HealthKit 要在描述文件里带 `com.apple.developer.healthkit` ——
///    侧载重签拿不到那个权限（本项目早就有定论：健康数据 App 侧不可行）。
///    更关键的是：**没那个权限时调用 HealthKit 的行为不受我们控制**
///    （最坏是系统直接把 App 杀掉），拿一个「反正也读不到」的可选字段
///    去赌「App 起不来」，性价比是负的。所以**不调用**，`steps` 这一项如实空着。
enum StatusCollector {

    // MARK: - 采集总入口

    /// 采一份完整快照。`location` 是定位管理器当前拿到的最新位置（可能为 nil）。
    static func collect(location: CLLocation?) async -> StatusSnapshot {
        var snap = StatusSnapshot()
        snap.collectedAt = Date()

        // 设备 / 电量：读 `UIDevice` 要在主线程上做。
        let device = await deviceInfo()
        snap.machine = device.machine
        snap.deviceName = device.name
        snap.systemName = device.systemName
        snap.systemVersion = device.systemVersion

        let battery = await batteryInfo()
        snap.hasBattery = battery.has
        snap.batteryLevel = battery.level
        snap.batteryCharging = battery.charging

        // 位置：坐标 + 速度 + 逆地理中文地名。
        if let location {
            snap.hasLocation = true
            snap.latitude = location.coordinate.latitude
            snap.longitude = location.coordinate.longitude
            snap.horizontalAccuracy = location.horizontalAccuracy
            if location.speed >= 0 {
                snap.hasSpeed = true
                snap.speed = location.speed
            }
            let place = await reverseGeocode(location)
            snap.place = place.full
            snap.city = place.city
            snap.district = place.district
            snap.street = place.street
        }

        // 网络：在线状态 + 接口类型。
        let network = await networkInfo()
        snap.hasNetwork = network.has
        snap.networkOnline = network.online
        snap.networkKind = network.kind

        // WiFi 名：尽力拿，拿不到就是空串。
        snap.wifiName = await wifiName()

        // 步数：**故意不采**（理由见文件头 —— 侧载签名没有 HealthKit 权限，
        //       调用它的行为不受控，不值得拿「App 能不能起来」去赌）。
        //       `hasSteps` 因此恒为 false，上报时不会出现 `steps` 这个键。

        return snap
    }

    // MARK: - 设备 / 电量（主线程）

    @MainActor
    static func deviceInfo() -> DeviceInfo {
        var info = DeviceInfo()
        info.machine = machineIdentifier()
        info.name = UIDevice.current.name
        info.systemName = UIDevice.current.systemName
        info.systemVersion = UIDevice.current.systemVersion
        return info
    }

    @MainActor
    static func batteryInfo() -> BatteryInfo {
        // 必须先打开电量监控，再去读 level / state，否则 level 恒为 -1。
        UIDevice.current.isBatteryMonitoringEnabled = true
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else { return BatteryInfo() }
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        return BatteryInfo(has: true, level: Int((raw * 100).rounded()), charging: charging)
    }

    /// 硬件代号（例如 `iPhone15,3`）。照抄 `Diagnostics.machine` 的 sysctl 写法。
    private static func machineIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "unknown" }
            return String(cString: base)
        }
    }

    // MARK: - 逆地理

    private static func reverseGeocode(
        _ location: CLLocation
    ) async -> (full: String, city: String, district: String, street: String) {
        let coordinate = location.coordinate
        let fallback = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)

        let geocoder = CLGeocoder()
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return (fallback, "", "", "")
        }

        let city = placemark.locality ?? placemark.administrativeArea ?? ""
        let district = placemark.subLocality ?? ""
        let street = placemark.thoroughfare ?? ""

        var parts: [String] = []
        if let area = placemark.administrativeArea, !area.isEmpty { parts.append(area) }
        if !city.isEmpty { parts.append(city) }
        if !district.isEmpty { parts.append(district) }
        if !street.isEmpty { parts.append(street) }

        let full = parts.isEmpty ? fallback : parts.joined(separator: " ")
        return (full, city, district, street)
    }

    // MARK: - 网络类型

    private static func networkInfo() async -> (has: Bool, online: Bool, kind: String) {
        let monitor = NWPathMonitor()
        let path: NWPath? = await withCheckedContinuation {
            (continuation: CheckedContinuation<NWPath?, Never>) in
            let once = OnceBox<NWPath?>(continuation)
            monitor.pathUpdateHandler = { current in
                once.finish(current)
            }
            monitor.start(queue: DispatchQueue(label: "com.aevis.status.network"))
        }
        monitor.cancel()

        guard let path else { return (false, false, "") }
        // 值用服务端契约里的英文（wifi / cellular / ethernet / other），
        // 界面显示时再翻成中文 —— 免得把中文直接发上去跟契约对不上。
        let kind: String
        if path.usesInterfaceType(.wifi) {
            kind = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            kind = "cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            kind = "ethernet"
        } else {
            kind = "other"
        }
        return (true, path.status == .satisfied, kind)
    }

    // MARK: - WiFi 名

    /// 尽力拿当前 WiFi 的 SSID。
    ///
    /// ⚠️ 这个包**没有** WiFi-info 那个权限，真机上 `fetchCurrent` 很可能直接回 nil ——
    ///    那就如实写空串，上报时**两个键（`wifi` 与 `wifiName`）都不写**，
    ///    **绝不报错、绝不卡住**。
    ///    这里用一个 3 秒兜底：万一回调迟迟不来，也不能让整次上报被它拖死。
    private static func wifiName() async -> String {
        if #available(iOS 14.0, *) {
            return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                let once = OnceBox<String>(continuation)
                NEHotspotNetwork.fetchCurrent { network in
                    once.finish(network?.ssid ?? "")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    once.finish("")
                }
            }
        }
        return ""
    }

    // MARK: - 步数（**故意不做**）

    // 这里原来有一段 HealthKit 的 `stepsToday()`。2026-10-09 整段删掉，理由见文件头：
    // 侧载重签的描述文件里没有 `com.apple.developer.healthkit`，读步数只能走 HealthKit，
    // 而没有该权限时调用它的行为不受我们控制 —— 为了一个「反正也读不到」的可选字段
    // 去赌「App 起不来」不划算。`StatusSnapshot.hasSteps` / `steps` 两个字段保留，
    // 将来若改由「快捷指令把步数喂进来」再填（那时它们就有用了）。
}

// MARK: - 小结构

/// 设备信息。
struct DeviceInfo {
    var machine: String = ""
    var name: String = ""
    var systemName: String = ""
    var systemVersion: String = ""
}

/// 电量信息。
struct BatteryInfo {
    var has: Bool = false
    var level: Int = 0
    var charging: Bool = false
}

/// 保证一个 `CheckedContinuation` **只被 resume 一次**。
///
/// `NWPathMonitor` 的回调会被调不止一次，而二次 resume 会**直接崩**；
/// WiFi 那条路还要额外加一个超时兜底 —— 同一个盒子两处都用得上。
private final class OnceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: T) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}
