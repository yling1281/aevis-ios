import AppIntents
import Foundation
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
/// 2. 一个 App 最多 **10** 条（Apple 建议 2–5 条），这里放 3 条；
/// 3. 这些动作**不能被 `shortcuts://run-shortcut?name=` 按名字调** —— 那条 URL 只认
///    用户自己库里的快捷指令。所以 Aevis 要用它们，只能在自己的代码里直接读
///    （下面三个 intent 就是把"读"这一步做进了 App 自己）。
///
/// ## 它和 `aevis://` 那条老路的关系
/// 读到的值**写进 `AmbientContext`**（她聊天时会看到），进的跟
/// `aevis://battery?level=57` 是**同一处存储、同一套保鲜期** —— 两条路只是入口不同。
/// 老路（用户自建快捷指令 + 「打开 URL」回传）**一条没动**，见 `AevisBridge`。
///
/// ⚠️ 读电量这类系统数据，**在 intent 里直接读**（我们自己就是 App 进程），
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

// MARK: - 出厂预置

/// 把上面三个 intent 变成「快捷指令」里 Aevis 分类下的动作。
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
    }
}
