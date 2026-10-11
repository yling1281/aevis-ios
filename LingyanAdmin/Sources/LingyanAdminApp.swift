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

/// 最外层：**两个后台共用一扇门**。
///
/// 顶上一根 `WorkspaceBar` 切「素材后台 / 码支付」，下面各自出自己的内容：
///   · 素材后台 —— 已登录 → `MainTabs`（5 个页签）；没登录 → `LoginView`
///   · 码支付   —— 已登录 → `PayTabs`（5 个页签）；没登录 → `PayLoginView`
///
/// ⚠️ 两边的登录态**完全独立**（两个单例、两套 UserDefaults key）：
///    码支付那边令牌过期 / 退出，不会把素材后台也踢出去。
///    合成一个的话，一边 401 会把另一边也清掉，用户会以为「App 老掉线」。
///
/// ⚠️ 这是「门」。加它的时候必须同时给截图自检留两条路（见 AppConfig / PayConfig）：
///    `-demo` 跳过它、`-showSetup` 强制显示它 —— 只留一条的话，
///    要么截图全变成同一屏，要么登录页永远截不到。
struct RootView: View {
    @ObservedObject private var cfg = AppConfig.shared
    @ObservedObject private var pay = PayConfig.shared

    /// 默认开在哪一侧由 `-ws` 决定（见 `Workspace.initial`）。
    @State private var ws: Workspace = Workspace.initial

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(ws: $ws)

            switch ws {
            case .sucai:
                if cfg.configured {
                    MainTabs()
                } else {
                    LoginView()
                }
            case .pay:
                if pay.configured {
                    PayTabs()
                } else {
                    PayLoginView()
                }
            }
        }
    }
}
