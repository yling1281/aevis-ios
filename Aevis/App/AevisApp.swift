import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

    init() {
        // 提前把用户导入过的字体注册好，免得第一帧找不到字体而回退成系统字体。
        _ = FontStore.shared
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
