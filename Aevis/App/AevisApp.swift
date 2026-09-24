import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

    init() {
        // 提前把用户导入过的字体注册好，免得第一帧找不到字体而回退成系统字体。
        _ = FontStore.shared

        // 只在 Debug 构建、且带了 -aevisDemo 启动参数时才写入演示数据，
        // 供 CI 在模拟器里截图自检用。正式使用完全不受影响。
        DemoSeed.applyIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
    }
}
