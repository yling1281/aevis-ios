import AppIntents
import Foundation
import Network
import UIKit

/// 「快捷指令」里**出厂自带**的动作 —— 装好 Aevis 就有，用户一下都不用手搓。
///
/// ## 为什么是这套写法（而不是"下载一个 .shortcut"）
/// iOS 15 起，「快捷指令」只肯导入 **Apple 签名过**的 `.shortcut`（AEA1 容器）；
/// 签名必须在登录了 Apple ID 的 Mac 上跑 `shortcuts sign`、还要联网让 Apple 验一遍 ——
/// 我们这台 Windows 开发机 + GitHub Actions **造不出可分发的文件**。这是苹果锁死的，
/// 不是实现问题。
///
/// 正规出路是 **App Intents / App Shortcuts**：App 用 Swift 声明动作，
/// **代码里声明一次，随 App 安装即出现在系统「快捷指令」App 的「App 快捷指令」分类里**，
/// 用户点一下就能跑 —— 免签名、免下载、免手搓。
///
/// ## 三条硬规矩（错了就**静默失效**，界面上什么都看不出来）
/// 1. 每个 phrase **必须含 `\(.applicationName)`**，否则那条动作不会出现在「快捷指令」里；
/// 2. 一个 App 最多 **10** 条（Apple 建议 2–5 条），这里放 7 条；
/// 3. 这些动作**不能被 `shortcuts://run-shortcut?name=` 按名字调** —— 那条 URL 只认
///    用户自己库里的快捷指令。所以 Aevis 要用它们，只能在自己的代码里直接读
///    （下面这些 intent 就是把"读"这一步做进了 App 自己）。
///
/// ## 它和 `aevis://` 那条老路的关系
/// 读到的值**写进 `AmbientContext`**（ta聊天时会看到），进的跟 `aevis://…` 是
/// **同一处存储、同一套保鲜期** —— 两条路只是入口不同。
/// 老路（用户自建快捷指令 + 「打开 URL」回传）**一条没动**，见 `AevisBridge`。
///
/// ⚠️ 读电量/机型这类系统数据，**在 intent 里直接读**（我们自己就是 App 进程），
///    比让用户拼「取电量 → 打开 URL」干净得多。读不到就如实说读不到，绝不编一个数。

// MARK: - 上报电量

/// 读一次电池，记进 `AmbientContext` 的「电量」那一格。
struct ReportBatteryIntent: AppIntent {

    static var title: LocalizedStringResource = "把电量发给 Aevis"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `batteryLevel` 在**没开监控**时恒为 -1.0，先打开监控再读。
        // 真机上偶尔也还是拿不到（返回 -1）—— 那就**返回"读不到"**，
        // 绝不要把 -1 当成真实电量写进去。
        let reading: (level: Int, charging: Bool) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let raw = UIDevice.current.batteryLevel
            let level = raw < 0 ? -1 : Int((raw * 100).rounded())
            let state = UIDevice.current.batteryState
            let charging = (state == .charging || state == .full)
            return (level, charging)
        }

        guard reading.level >= 0 else {
            return .result(dialog: "读不到电量 —— 这台机器上没拿到这个数。")
        }

        let text = reading.charging
            ? "\(reading.level)%，在充电"
            : "\(reading.level)%，没在充电"

        // AmbientContext 是 @Published，必须在主线程上写（iOS 26 从后台写会硬崩）。
        _ = await MainActor.run {
            AmbientContext.shared.ingest(kind: "battery", text: text)
        }
        return .result(dialog: "已把电量告诉 Aevis：\(text)")
    }
}

// MARK: - 上报位置

/// 取一次定位，记进 `AmbientContext` 的「位置」那一格。
///
/// 定位这一步**直接复用** `LocationReader`（`SenseTools.swift` 里那个一次性读取，
/// 已经标了 `@MainActor`、处理了授权时序）—— 不另起一套 CoreLocation 代码，
/// 免得在"本机编不了、只能等 CI"的情况下多一处会出错的地方。
struct ReportLocationIntent: AppIntent {

    static var title: LocalizedStringResource = "把位置发给 Aevis"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let place = await LocationReader.current() else {
            return .result(dialog: "没拿到位置 —— 看看定位权限，或者稍后再试。")
        }

        var parts: [String] = []
        if !place.name.isEmpty { parts.append(place.name) }
        if let latitude = place.latitude, let longitude = place.longitude {
            let lat = String(format: "%.5f", latitude)
            let lon = String(format: "%.5f", longitude)
            parts.append("(\(lat), \(lon))")
        }
        let text = parts.isEmpty ? "位置" : parts.joined(separator: " ")

        _ = await MainActor.run {
            AmbientContext.shared.ingest(kind: "location", text: text)
        }
        return .result(dialog: "已把位置告诉 Aevis：\(text)")
    }
}

// MARK: - 我在干嘛

/// 用户在「快捷指令」里打一句话（比如「在回家的地铁上」），
/// 记进 `AmbientContext` 的「其它」那一格。
///
/// 挑 `device` 这一格的理由：`AmbientContext.kinds` 里它的标签就是「其它」，
/// 示例写着 `aevis://device?text=现在在回家的地铁上` —— 本来就是"随手报一句"用的
/// 兜底格子，正好装"我在干嘛"。**没有另建键名**（不动已有键与保鲜期）。
struct TellAevisIntent: AppIntent {

    static var title: LocalizedStringResource = "告诉 Aevis 我在干嘛"

    @Parameter(title: "在干嘛")
    var activity: String

    static var parameterSummary: some ParameterSummary {
        Summary("告诉 Aevis 我在干嘛")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .result(dialog: "没说要干嘛，没记下。")
        }
        _ = await MainActor.run {
            AmbientContext.shared.ingest(kind: "device", text: text)
        }
        return .result(dialog: "记下了：\(text)")
    }
}

// MARK: - 设备详细信息

/// 采集"这台机器是什么"，记进 `AmbientContext` 的「设备」那一格。
///
/// 🔴 存的是 `deviceinfo`，**不是** `device` —— `device` 是「其它 / 随手记一句」的
///    兜底格（`TellAevisIntent`、`aevis://device?text=` 都在用），若也写进 `device`
///    会跟"我在干嘛"**互相覆盖**。
struct ReportDeviceInfoIntent: AppIntent {

    static var title: LocalizedStringResource = "把设备信息发给 Aevis"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let network = await NetworkKindReader.current()
        let text = await AevisDevice.summary(network: network)
        _ = await MainActor.run {
            AmbientContext.shared.ingest(kind: "deviceinfo", text: text)
        }
        return .result(dialog: "已把设备信息告诉 Aevis：\(text)")
    }
}

// MARK: - 打开 App

/// 把 Aevis 带到前台。
///
/// ⚠️ iOS 26 里 `openAppWhenRun` 已废弃、官方推荐 `supportedModes`，
///    但这里**故意沿用旧写法**：废弃只产生一条"过时"**警告**（不是错误 —— 苹果从不会
///    在同一个 SDK 里既给出替换项、又把旧项变成不可用，那会让所有用到它的 App 当场编不过）。
///    行为跟 `supportedModes = .foreground(.immediate)` **完全一样**。
///    🔴 **⚠️ 待 CI 验证**：本机没有 Xcode/SDK，无法 100% 确认 iOS 26 SDK 把它标成
///    deprecated（=警告）而不是 unavailable（=错误）。**若 CI 真报错**，就换成
///    `static var supportedModes: IntentModes { .foreground(.immediate) }`。
struct OpenAevisIntent: AppIntent {

    static var title: LocalizedStringResource = "打开 Aevis"

    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        return .result(dialog: "Aevis 这就来。")
    }
}

// MARK: - 上报健康

/// 健康数据的**接收端**：让用户在系统「快捷指令」里把「查找健康样本 / 统计健康样本」
/// 的结果**直接拖进这个动作的参数**，记进 `AmbientContext` 的「健康」那一格。
///
/// 为什么只能这样：**Aevis 自己的 intent 读不了 HealthKit** —— 健康数据要
/// `com.apple.developer.healthkit` 能力（entitlement），而侧载重签用的描述文件里没有它
/// （卡的是**签名**，不是**代码**）。所以这条路只能是：**系统快捷指令自己读健康**，
/// 再把结果喂给我们；我们当好"接收端"。
///
/// 参数类型用 `String` —— 这样在快捷指令里能点进去，把上游动作的变量拖进来。
struct ReportHealthIntent: AppIntent {

    static var title: LocalizedStringResource = "把健康数据发给 Aevis"

    @Parameter(title: "内容")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$text)发给 Aevis")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return .result(dialog: "没读到你想要的内容 —— 先确认健康里真有数据。")
        }
        // AmbientContext 是 @Published，必须在主线程上写（和同文件其它 intent 一致）。
        let note = await MainActor.run {
            AmbientContext.shared.ingest(kind: "health", text: value)
        }
        return .result(dialog: "\(note)")
    }
}

// MARK: - 上报屏幕使用时间

/// 屏幕使用时间的**接收端**：让用户在系统「快捷指令」里把上游动作（系统「屏幕使用时间」
/// 那一类动作，或者干脆自己手填一个数字）的结果**直接拖进这个动作的参数**，灌进 App。
///
/// 为什么只能这样（和 `ReportHealthIntent` 是**同一个道理**）：**Aevis 自己读不了**屏幕
/// 使用时间 —— 这数据属于苹果的「家庭控制」（Family Controls），要单独的 entitlement，
/// 而侧载重签用的描述文件里**没有**它；更要命的是没权限时调它的框架**不是返回「没权限」
/// 而是直接崩**。卡的是**签名**，不是**代码** —— 代码写得再对，签名不到位就是拿不到。
/// 所以路子只能是：**系统快捷指令自己读 / 用户自己填，再把结果喂给我们**；我们当好「接收端」。
///
/// ⚠️ 屏幕使用时间的**官方快捷指令动作在不同 iOS 版本上不一定有** —— 所以这个动作
///    同时**必须能接「手填」的数字**：`minutes` 就是个普通的 `Int` 参数，可以在快捷指令里
///    点进去手输，也可以把上游变量拖进来，两条路都通。
///
/// 参数为什么是 `String?`/`Int`（而不是直接调 API）：只有参数是「可拖入的变量」，
/// 快捷指令里才能把上游动作的输出拖进来。解析、落库**一律交给
/// `ScreenTimeInsight.ingest`**（它会读 `minutes`/`top` 两个键，返回一句给用户看的话），
/// 这里**不自己解析数字、不自己写 UserDefaults**。
struct ReportScreenTimeIntent: AppIntent {

    static var title: LocalizedStringResource = "把屏幕使用时间发给 Aevis"

    @Parameter(title: "总分钟数")
    var minutes: Int

    @Parameter(title: "用得最多的 App")
    var top: String?

    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$minutes)分钟的屏幕使用时间发给 Aevis")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `ScreenTimeInsight.latest` 是 `@Published`，必须在主线程上写
        // （iOS 26 从后台线程写会硬崩；同文件其它 intent 全是 `await MainActor.run { … }` 这个写法）。
        // 解析 + 落库全在 `ingest` 里，我们只负责把参数递进去、把回话原样吐出来。
        let note = await MainActor.run {
            ScreenTimeInsight.ingest(["minutes": "\(minutes)", "top": top ?? ""])
        }
        return .result(dialog: "\(note)")
    }
}

// MARK: - 出厂预置

/// 把上面的 intent 变成「快捷指令」里 Aevis 分类下的动作。
///
/// ⚠️ 这个类型**必须待在主 App target 里**（`Aevis/Core/` 就在主 target）。
///    放进扩展的话，intent 只能后台跑，读电量这类要前台的能力会拿不到。
struct AevisAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReportBatteryIntent(),
            phrases: [
                "把电量发给\(.applicationName)",
                "用\(.applicationName)看还剩多少电"
            ],
            shortTitle: "上报电量",
            systemImageName: "battery.100"
        )
        AppShortcut(
            intent: ReportLocationIntent(),
            phrases: [
                "把位置发给\(.applicationName)",
                "告诉\(.applicationName)我在哪"
            ],
            shortTitle: "上报位置",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: TellAevisIntent(),
            phrases: [
                "告诉\(.applicationName)我在干嘛",
                "用\(.applicationName)记一句我在干嘛"
            ],
            shortTitle: "我在干嘛",
            systemImageName: "figure.walk"
        )
        AppShortcut(
            intent: ReportDeviceInfoIntent(),
            phrases: [
                "用\(.applicationName)看设备信息",
                "告诉\(.applicationName)我的设备信息"
            ],
            shortTitle: "设备信息",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: OpenAevisIntent(),
            phrases: [
                "打开\(.applicationName)",
                "用\(.applicationName)打开自己"
            ],
            shortTitle: "打开 Aevis",
            systemImageName: "arrow.up.forward.app"
        )
        AppShortcut(
            intent: ReportHealthIntent(),
            phrases: [
                "把健康发给\(.applicationName)",
                "用\(.applicationName)记一下健康"
            ],
            shortTitle: "上报健康",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: ReportScreenTimeIntent(),
            phrases: [
                "把屏幕使用时间发给\(.applicationName)",
                "用\(.applicationName)记一下屏幕使用时间"
            ],
            shortTitle: "上报屏幕时间",
            systemImageName: "hourglass"
        )
    }
}

// MARK: - 网络类型

/// 当前网络是 WiFi 还是蜂窝。
///
/// 用 `NWPathMonitor`（**后台也能用**，不像 `UIScreen` 那样要前台 scene）。
/// `start(queue:)` 之后系统**必定**会回调一次（给当前路径），所以不会一直等不到。
enum NetworkKindReader {

    static func current() async -> String {
        let monitor = NWPathMonitor()
        let value: String = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            monitor.pathUpdateHandler = { path in
                once.finish(describe(path))
            }
            monitor.start(queue: DispatchQueue(label: "com.aevis.networkkind"))
        }
        monitor.cancel()
        return value
    }

    private static func describe(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "WiFi" }
        if path.usesInterfaceType(.cellular) { return "蜂窝网络" }
        if path.usesInterfaceType(.wiredEthernet) { return "有线网络" }
        if path.status == .satisfied { return "在线" }
        return "离线"
    }
}

/// 保证 continuation **只被 resume 一次**。
///
/// `NWPathMonitor` 的回调会被调**不止一次**，而二次 resume 一个 `CheckedContinuation`
/// 会**直接崩**（不是抛错）—— 所以这里上锁 + 一个"已经交过卷"的标志。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<String, Never>

    init(_ continuation: CheckedContinuation<String, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: String) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        guard shouldResume else { return }
        continuation.resume(returning: value)
    }
}

// MARK: - 读设备

/// 读"这台机器"的几样东西。**全部后台可读**
/// （故意不碰 `UIScreen` —— 它要前台 scene，后台拿不到）。
enum AevisDevice {

    /// 机器标识 → 好懂的营销名。表里没有的返回 `nil`（调用方退回显示机器标识本身）。
    static func marketingName(for identifier: String) -> String? {
        names[identifier]
    }

    /// 一句话把"这台机器"说清楚。跑在主线程上（读 `UIDevice` 方便）。
    @MainActor
    static func summary(network: String) -> String {
        var parts: [String] = []

        // 机型：机器标识**复用现成的 `Diagnostics.machine`**（`Diagnostics.swift`，
        // 别把 sysctl 那套再写一遍）。营销名查得到就用；查不到**原样显示机器标识**，
        // 绝不猜名字；连标识都读不到才说"未知设备"。
        let identifier = Diagnostics.machine
        if let name = marketingName(for: identifier) {
            parts.append(name)
        } else if identifier.isEmpty || identifier == "unknown" {
            parts.append("未知设备")
        } else {
            parts.append(identifier)
        }

        parts.append("iOS \(UIDevice.current.systemVersion)")

        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        if memoryGB > 0 { parts.append("\(memoryGB)GB 内存") }

        if let storage = storageSummary() { parts.append(storage) }
        if let battery = batterySummary() { parts.append(battery) }

        parts.append(network)
        parts.append(localeSummary())
        parts.append(gmtSummary())

        if ProcessInfo.processInfo.isLowPowerModeEnabled { parts.append("省电模式") }

        return parts.joined(separator: "，")
    }

    // MARK: - 零件

    private static func storageSummary() -> String? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              total > 0 else { return nil }
        // 用十进制 GB（跟苹果标称一致），四舍五入到整数。
        let totalGB = Int((Double(total) / 1_000_000_000).rounded())
        let freeGB = Int((Double(free) / 1_000_000_000).rounded())
        return "存储 \(totalGB)GB 剩 \(freeGB)GB"
    }

    private static func batterySummary() -> String? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let raw = UIDevice.current.batteryLevel
        guard raw >= 0 else { return nil }
        let level = Int((raw * 100).rounded())
        let state = UIDevice.current.batteryState
        let charging = (state == .charging || state == .full)
        return charging ? "电量 \(level)% 充电中" : "电量 \(level)%"
    }

    private static func localeSummary() -> String {
        let locale = Locale.current
        let code = locale.language.languageCode?.identifier ?? ""
        let script = locale.language.script?.identifier

        let language: String
        if code == "zh" {
            language = (script == "Hant") ? "繁体中文" : "简体中文"
        } else if !code.isEmpty, let name = locale.localizedString(forLanguageCode: code) {
            language = name
        } else {
            language = code.isEmpty ? "未知语言" : code
        }

        let regionCode = locale.region?.identifier ?? ""
        let region = locale.localizedString(forRegionCode: regionCode) ?? regionCode
        return region.isEmpty ? language : "\(language)·\(region)"
    }

    private static func gmtSummary() -> String {
        let offset = TimeZone.current.secondsFromGMT()
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let sign = offset < 0 ? "-" : "+"
        if minutes == 0 { return "GMT\(sign)\(abs(hours))" }
        return String(format: "GMT%@%d:%02d", sign, abs(hours), minutes)
    }

    /// `hw.machine` → 营销名。
    ///
    /// ⚠️ **只放有把握的型号。** 表里没有的一律退回显示机器标识 ——
    ///    猜错一个名字（比如把 16 Plus 说成 16 Pro）比显示 `iPhone17,4` 更糟。
    ///    iPad 的标识又多又杂，这里**故意不收**，iPad 上就显示 `iPad…` 原始标识。
    ///
    /// 🔴🔴 **这张表里的值必须是纯 ASCII，一个中文都别放。**
    ///    这里出来的名字会被塞进 HTTP 头 `X-Aevis-Device-Name` 发给账号服务器
    ///    （见 `DeviceIdentity.friendlyName` / `AccountService.request()`），
    ///    而 **HTTP 头只认 latin-1** —— 值里有非 ASCII 字符，`URLRequest` 会在
    ///    **每一个账号请求上**出错，表现是「这几款机型登不上账号 / 一直转圈」。
    ///    2026-10-06 真验出来过：原本写着 `iPhone SE（第 2 代）`（全角括号 + 中文），
    ///    机器是 SE 2/3 的用户一点就中。已改成 `iPhone SE (2nd gen)`。
    ///    兜底在 `DeviceIdentity.sanitize`，但**别指望它** —— 那里是把中文字符**删掉**，
    ///    出来的是「iPhone SE 2」这种半截名字，能用但不好看。
    private static let names: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7",
        "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,8": "iPhone XR", "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max", "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus"
    ]
}
