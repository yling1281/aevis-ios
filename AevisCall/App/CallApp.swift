import SwiftUI

/// ## 「Aevis 通话」—— 让灵动岛上弹出**真正的苹果系统通话界面**（独立小包）
///
/// 老板 2026-10-01 拍板的架构：**谁的签名能弹灵动岛，就让谁弹；主 App 只管存数据。**
/// 这个包是那个「谁」：它跟跑通的探针（`AevisCallProbe`）一样是
/// **单可执行文件、单签名、不嵌任何扩展** —— 这个形状才弹得出系统通话界面。
///
/// ## 这一版到哪
/// 只做空壳：**起来 → 弹系统通话界面（灵动岛 / 锁屏）→ 挂断**，
/// 外加可自定义的来电头像与名字（见 `CallIdentityStore`）。
/// 不接声音、不接通讯录、不接 LLM —— 那是后续步骤（设计稿第 8 节）。
/// 理由：**空壳都弹不出来，后面全白做。**
///
/// ## ⚠️ 包里绝不嵌套扩展
/// `project.yml` 里这个 target 只编 `AevisCall/App` 这一份源码，
/// 探针真机验过：「只有一个 bundle、一份签名」这个形状才能弹系统通话界面。
///
/// ## ⚠️ 两个共享对象的读法
/// 用 `CallShell.shared` / `CallIdentityStore.shared`（而不是 `()`）——
/// App 的 `@StateObject` 默认值表达式在非主 actor 上下文里求值，
/// 直接调主 actor 隔离的初始化器是硬错误；读 `shared` 这套是验证过能编过的。
@main
struct CallApp: App {
    @StateObject private var shell = CallShell.shared
    @StateObject private var identity = CallIdentityStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(shell)
                .environmentObject(identity)
        }
    }
}
