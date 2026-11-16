import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var session = Session.shared

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // 137：CI 截图用，**只在 Debug 编进去**（Release 里这段物理上不存在）。
                // 模拟器是全新安装、没有登录态，带 `-demo` 启动时直接渲染聊天页（样例数据、不发请求）。
                // NSLog 那个标记是给 CI 断言用的：看不到它就说明参数没生效，别把登录页当截图交上去。
                if ProcessInfo.processInfo.arguments.contains("-demo") {
                    NavigationStack {
                        ChatView(
                            persona: Persona(
                                id: "demo_persona",
                                name: "季焚时",
                                tagline: "你回来啦",
                                avatar: ""
                            ),
                            demo: true
                        )
                        .onAppear { NSLog("AEVIS_DEMO_ON") }
                    }
                } else if session.token == nil {
                #else
                if session.token == nil {
                #endif
                    LoginView()
                } else {
                    ChatListView()
                }
            }
            .environmentObject(session)
            .preferredColorScheme(nil)   // 跟随系统（与安卓 120 的口径一致）
        }
    }
}
