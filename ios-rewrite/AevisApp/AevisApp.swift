import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var session = Session.shared

    /// 正常入口：冷启动校验先占位（避免闪一下聊天列表），没登录去登录页，登录了进会话列表。
    @ViewBuilder private var root: some View {
        if session.validating {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.token == nil {
            LoginView()
        } else {
            ChatListView()
        }
    }

    #if DEBUG
    /// 截图模式：`-demo chat|list|login`
    private var demoMode: String {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo") else { return "chat" }
        let next = i + 1 < args.count ? args[i + 1] : ""
        return ["chat", "list", "login"].contains(next) ? next : "chat"
    }

    @ViewBuilder
    private func demoRoot(mode: String) -> some View {
        switch mode {
        case "list":
            ChatListView(demo: true)
        case "login":
            LoginView()
        default:
            NavigationStack {
                ChatView(
                    persona: Persona(
                        id: "demo_persona", name: "季焚时",
                        tagline: "你回来啦", avatar: ""
                    ),
                    demo: true
                )
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                // CI 截图专用：带 `-demo` 启动时直接渲染聊天页（样例数据、不发请求）。
                // Release 编译后这段物理上不存在；NSLog 供 CI 断言。
                // 不要把 if/else 链拆到 #if/#else 两侧，Swift 会报
                // "expected '}' at end of brace statement"（2026-11-17 实际踩过）。
                // `-demo` 后面可选跟一个屏幕名：chat（默认）/ list / login。
                // CI 就是靠它连拍三张图；Release 里整段不存在。
                if ProcessInfo.processInfo.arguments.contains("-demo") {
                    demoRoot(mode: demoMode)
                        .onAppear { NSLog("AEVIS_DEMO_ON \(demoMode)") }
                } else {
                    root
                }
                #else
                root
                #endif
            }
            .environmentObject(session)
            .preferredColorScheme(nil)   // 跟随系统（与安卓 1.1.10 一致）
        }
    }
}
