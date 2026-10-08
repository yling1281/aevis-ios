import Foundation

/// 一次采集到的手机状态快照。
///
/// 所有字段都给默认值、**不用可选** —— 这样编码出来永远是一份完整的 JSON，
/// 界面读的时候也不用来回解包。真正的「有没有拿到这一项」用旁边的 `has…` 标志表达。
struct StatusSnapshot: Codable {
    /// 采集时刻。
    var collectedAt: Date = Date()

    // MARK: 位置
    var hasLocation: Bool = false
    var latitude: Double = 0
    var longitude: Double = 0
    var horizontalAccuracy: Double = 0
    var hasSpeed: Bool = false
    var speed: Double = 0
    /// 逆地理出来的中文地名；查不到就退化成经纬度字符串。
    var place: String = ""
    var city: String = ""
    var district: String = ""
    var street: String = ""

    // MARK: 电量
    var hasBattery: Bool = false
    var batteryLevel: Int = 0
    var batteryCharging: Bool = false

    // MARK: 设备
    var machine: String = ""
    var deviceName: String = ""
    var systemName: String = ""
    var systemVersion: String = ""

    // MARK: 网络
    var hasNetwork: Bool = false
    var networkOnline: Bool = false
    var networkKind: String = ""

    // MARK: WiFi
    /// 拿不到就是空串（上报那一刻转成 null）。
    var wifiName: String = ""

    // MARK: 步数
    var hasSteps: Bool = false
    var steps: Int = 0
}

/// 最近一次上报的结果。
struct StatusUploadResult: Codable {
    var at: Date = Date()
    var success: Bool = false
    var status: Int = 0
    /// 服务器返回的原话（截前 200 字）；网络层失败时是本地错误描述。
    var message: String = ""
}

/// 「Aevis 状态」App 的本地设置与最近状态。
///
/// 照 `CoupleStore` 的习惯写：`ObservableObject` + `@Published`，
/// 要留下来的东西第一时间落 `UserDefaults`。
///
/// ⚠️ 上报密钥**只存在 `UserDefaults`**，由用户在界面里填一次 ——
///    绝不硬编码进源码（项目铁律）。
///
/// ⚠️ 这个类里**故意一个 async 方法都没有**：所有要改 `@Published` 的写入口
///    都是同步方法，由调用方保证在主线程上调用（见 `StatusService`）。
///    这样就不会踩「await 之后线程随机、改 @Published 在 iOS 26 上硬崩」那个坑。
final class StatusStore: ObservableObject {
    static let shared = StatusStore()

    /// 默认上报地址。密钥不在这里、也没有默认值。
    static let defaultReportURL = "https://lingyan.cyou/shensi-phone/report"

    /// 上报地址。改了立刻落盘。
    @Published var reportURL: String = StatusStore.defaultReportURL {
        didSet { persistSettings() }
    }
    /// 上报密钥。改了立刻落盘。
    @Published var reportKey: String = "" {
        didSet { persistSettings() }
    }
    /// 总开关。关掉之后任何触发点都不再打服务器。
    @Published var enabled: Bool = true {
        didSet { persistSettings() }
    }

    /// 最近一次采集到的快照。
    @Published var lastSnapshot: StatusSnapshot?
    /// 最近一次上报的结果。
    @Published var lastResult: StatusUploadResult?
    /// 正在上报（界面上用来禁用按钮）。
    @Published var loading: Bool = false
    /// 一行临时提示（比如「正在上报」/「刚报过，先跳过」）。
    @Published var note: String = ""
    /// 定位权限的**如实**状态，直接显示在界面上。
    @Published var locationStatus: String = "还没请求定位权限"

    private let defaults = UserDefaults.standard

    /// 读档期间禁写。理由同 `CoupleStore.loading`：
    /// 读盘时给 `reportURL` 赋值会触发 `didSet`，而 `persistSettings()` 会
    /// 把**另外两个**还没读出来的键用默认值覆盖掉 —— 必须挡住。
    private var suppressPersist = false

    private enum Keys {
        static let url = "aevis.status.url"
        static let key = "aevis.status.key"
        static let enabled = "aevis.status.enabled"
        static let snapshot = "aevis.status.snapshot"
        static let result = "aevis.status.result"
    }

    /// 是否已经填过密钥（界面拿它决定要不要提醒）。
    var hasKey: Bool {
        !reportKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init() {
        load()
    }

    // MARK: - 写入

    /// 记下一次采集结果（同步，调用方保证在主线程）。
    func apply(snapshot: StatusSnapshot) {
        lastSnapshot = snapshot
        save(snapshot)
    }

    /// 记下一次上报结果（同步，调用方保证在主线程）。
    func apply(result: StatusUploadResult) {
        lastResult = result
        save(result)
    }

    // MARK: - 落盘

    private func persistSettings() {
        guard !suppressPersist else { return }
        defaults.set(reportURL, forKey: Keys.url)
        defaults.set(reportKey, forKey: Keys.key)
        defaults.set(enabled, forKey: Keys.enabled)
    }

    private func save(_ snapshot: StatusSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Keys.snapshot)
    }

    private func save(_ result: StatusUploadResult) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        defaults.set(data, forKey: Keys.result)
    }

    private func load() {
        suppressPersist = true
        defer { suppressPersist = false }

        if let url = defaults.string(forKey: Keys.url), !url.isEmpty {
            reportURL = url
        }
        reportKey = defaults.string(forKey: Keys.key) ?? ""
        if defaults.object(forKey: Keys.enabled) != nil {
            enabled = defaults.bool(forKey: Keys.enabled)
        }
        if let data = defaults.data(forKey: Keys.snapshot),
           let snapshot = try? JSONDecoder().decode(StatusSnapshot.self, from: data) {
            lastSnapshot = snapshot
        }
        if let data = defaults.data(forKey: Keys.result),
           let result = try? JSONDecoder().decode(StatusUploadResult.self, from: data) {
            lastResult = result
        }
    }
}
