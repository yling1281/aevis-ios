import SwiftUI

/// ## 手机状态上报 App
///
/// 把位置 / 电量 / 机型 / 网络 / WiFi / 步数采下来，定时 POST 给服务器
/// （默认地址与上报密钥都在界面里填、只存在本机 `UserDefaults`）。
///
/// ⚠️ 包名 / bundle id / 权限文案都在 `project.yml` 与 `Info.plist` 里
///    （`com.aevis.status`，显示名「Aevis 状态」）。**这里不改 Info.plist**。
///
/// ⚠️ 一进 App 就把 `StatusService` 拉起来：它会请求定位权限、
///    启动静音音频保活（`SilentKeeper`）、挂上 10 分钟定时器并立刻上报一次。
@main
struct StatusApp: App {

    init() {
        StatusService.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            SettingsView()
        }
    }
}
