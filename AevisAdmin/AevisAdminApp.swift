import SwiftUI
import UIKit

/// Aevis 管理端 —— 独立的 App，**不塞进 Aevis 主 App 里**。
///
/// 主 App 是给买家用的（创造恋人、聊天），这个是给管理员用的
/// （看崩溃现场、发码、封设备、批换机）。两拨人的东西混在一个包里
/// 既容易互相影响，也没法分开更新。
@main
struct AevisAdminApp: App {
    var body: some Scene {
        WindowGroup {
            AdminGate()
                .environmentObject(AdminStore.shared)
                // `.task` 天生跑在 MainActor 上 —— 单例要从这里碰，
                // 别写在 `App.init()` 里（那儿不是主线程隔离的）。
                .task { AdminStore.shared.restore() }
        }
    }
}

/// 没登录 → 登录页；登录了 → 主界面。
struct AdminGate: View {
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        if store.isSignedIn {
            AdminRootView()
        } else {
            AdminLoginView()
        }
    }
}
