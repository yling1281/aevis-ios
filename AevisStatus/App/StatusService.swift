import CoreLocation
import Foundation
import UIKit

/// 采集 + 上报的总调度：定位管理器、定时器、各种触发点都在这里。
///
/// 触发点（每个都接上了）：
///   1. App 启动；
///   2. 回到前台（`didBecomeActiveNotification`）；
///   3. 位置显著变化（`startMonitoringSignificantLocationChanges` 的回调）；
///   4. 界面上的「立刻上报一次」按钮。
/// 外加一个 **10 分钟**的定时器（靠 `SilentKeeper` 的静音音频让 App 在后台活着）。
///
/// ⚠️ **同一次上报要节流**：60 秒内不重复打服务器（避免恰好在同一时刻被好几个触发点一起点名）。
///
/// ⚠️ 这个类的方法都在主线程上被调用（SwiftUI / Timer / 通知 / 定位回调都在主线程），
///    唯一离开主线程的是「采集 + 网络」那一段 —— 它跑在 `Task` 里，
///    回写界面状态时用 `MainActor.run` 跳回主线程。
final class StatusService: NSObject, CLLocationManagerDelegate {

    static let shared = StatusService()

    private let store = StatusStore.shared
    private let manager = CLLocationManager()
    private var timer: Timer?
    private var lastUploadAt = Date.distantPast
    private var lastLocation: CLLocation?
    /// 「始终允许」只问一次，避免反复弹框。
    private var didAskAlways = false

    private override init() {
        super.init()
        manager.delegate = self
        // 省电档就够用：我们只想知道城市 / 街区，不需要米级精度。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.pausesLocationUpdatesAutomatically = false
        // Info.plist 里有 UIBackgroundModes = [location]，这里才敢开。
        manager.allowsBackgroundLocationUpdates = true
    }

    // MARK: - 启动

    func start() {
        requestInitialAuthorization()
        SilentKeeper.shared.start()
        scheduleTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil)
        trigger(reason: "启动")
    }

    private func requestInitialAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // 先要「使用期间」，用户答应之后再在回调里去要「始终」。
            manager.requestWhenInUseAuthorization()
        default:
            startMonitoring()
        }
    }

    // MARK: - 定时器

    private func scheduleTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            self?.trigger(reason: "定时")
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func appDidBecomeActive() {
        // 回到前台时音频会话可能被系统动过，顺手补一次（幂等）。
        SilentKeeper.shared.start()
        trigger(reason: "回到前台")
    }

    // MARK: - 触发

    func trigger(reason: String, manual: Bool = false) {
        guard store.enabled else {
            if manual { store.note = "上报开关是关的" }
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastUploadAt) < 60 {
            if manual { store.note = "距上次上报不到 60 秒，这次先跳过" }
            return
        }
        lastUploadAt = now
        store.note = "正在上报（\(reason)）"
        Task { await report(reason: reason) }
    }

    /// 采集一份快照并上报。跑在后台，回写界面状态时跳回主线程。
    private func report(reason: String) async {
        await MainActor.run { store.loading = true }
        let snapshot = await StatusCollector.collect(location: lastLocation)
        await MainActor.run { store.apply(snapshot: snapshot) }

        let url = store.reportURL
        let key = store.reportKey
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await MainActor.run {
                store.loading = false
                store.note = "还没填上报密钥，先在下面填一个"
            }
            return
        }

        let result = await StatusUploader.upload(snapshot: snapshot, urlString: url, key: key)
        await MainActor.run {
            store.apply(result: result)
            store.loading = false
            store.note = result.success ? "上报成功（\(reason)）" : "上报失败（\(reason)）"
        }
    }

    // MARK: - 定位授权

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        updateLocationStatus(status)
        switch status {
        case .authorizedWhenInUse:
            if !didAskAlways {
                didAskAlways = true
                manager.requestAlwaysAuthorization()
            }
            startMonitoring()
        case .authorizedAlways:
            startMonitoring()
        default:
            // 被拒 / 未决定：什么都不做，绝不死循环弹框。
            break
        }
    }

    private func updateLocationStatus(_ status: CLAuthorizationStatus) {
        let text: String
        switch status {
        case .notDetermined: text = "还没请求定位权限"
        case .restricted: text = "定位被系统限制"
        case .denied: text = "定位被拒绝（可在系统设置里打开）"
        case .authorizedWhenInUse: text = "定位：仅使用期间"
        case .authorizedAlways: text = "定位：始终允许"
        @unknown default: text = "定位状态未知"
        }
        store.locationStatus = text
    }

    private func startMonitoring() {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }
        // 位置显著变化：后台也会被唤醒，顺带就是一次上报触发点。
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
    }

    // MARK: - 定位回调

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastLocation = location
        trigger(reason: "位置变化")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失败什么都不做：等下一次回调，绝不让 App 崩。
    }
}
