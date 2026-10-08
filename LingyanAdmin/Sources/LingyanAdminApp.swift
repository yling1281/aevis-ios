import SwiftUI

@main
struct LingyanAdminApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay(ToastOverlay())
        }
    }
}

/// 最外层：没登录就先看登录页，登进去进正片。
///
/// ⚠️ 这是个「门」。加它的时候必须同时给截图自检留两条路（见 AppConfig）：
///    `-demo` 跳过它、`-showSetup` 强制显示它 —— 只留一条的话，
///    要么截图全变成同一屏，要么登录页永远截不到。
struct RootView: View {
    @ObservedObject private var cfg = AppConfig.shared

    var body: some View {
        Group {
            if cfg.configured {
                MainTabs()
            } else {
                LoginView()
            }
        }
    }
}
