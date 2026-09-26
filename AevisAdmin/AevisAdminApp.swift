import SwiftUI
import UIKit

/// Aevis 管理端 —— 独立的 App，**不塞进 Aevis 主 App 里**。
///
/// 主 App 是给买家用的（创造恋人、聊天），这个是给管理员用的
/// （看崩溃现场、发码、封设备、批换机）。两拨人的东西混在一个包里
/// 既容易互相影响，也没法分开更新。
@main
struct AevisAdminApp: App {
    /// ⚠️ 单例**在这里**第一次被碰到。`@StateObject` 的默认值是 SwiftUI
    /// 在 body 阶段求值的（那时一定在主线程上），所以 `AdminStore()` 建在主线程 ——
    /// 而它是 `@MainActor` 的类，这一点必须成立（"音乐闪退"就是栽在这类地方）。
    ///
    /// 两件**不要**做的事：
    /// ① 别在 `App.init()` 里手写 `AdminStore.shared` —— `App.init` 不是主 actor
    ///    隔离的，在那边碰一个 `@MainActor` 的类会出问题；
    /// ② 别用 `.task { store.restore() }` 去恢复登录态 —— 那件事已经放进
    ///    `AdminStore.init()` 里了（在 init 里做的成本是零，也省得跟隔离规则较劲）。
    @StateObject private var store = AdminStore.shared

    var body: some Scene {
        WindowGroup {
            AdminGate()
                .environmentObject(store)
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
