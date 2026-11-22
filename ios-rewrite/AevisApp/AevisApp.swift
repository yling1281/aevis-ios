import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var session = Session.shared
    /// 更新门禁：挂在 root 外层，force 时盖住登录页 / 主界面。
    /// shared 单例用 ObservedObject 即可（生命周期由单例自己管）。
    @ObservedObject private var update = AppUpdateCenter.shared

    /// CI 截图模式（-demo）下不检查更新、不弹窗，避免网络和弹窗干扰截图。
    private var isDemo: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        return false
        #endif
    }

    /// 更新弹窗的显示绑定：完全由 `AppUpdateCenter.shouldPrompt` 驱动。
    ///
    /// 强制更新「进不去」的关键：`set` 故意留空 —— 忽略任何来自 UIKit 层的关闭请求
    /// （系统手势、代码 dismiss），只要 `shouldPrompt` 仍为 true，sheet 就保持显示。
    /// 配合 `UpdateSheet` 内的 `.interactiveDismissDisabled(true)`，用户无法绕过。
    /// 非强制更新点「稍后」会调 `center.dismiss()` 置 `dismissed = true`，
    /// `shouldPrompt` 随之变 false，sheet 自然关闭 —— 无需 onDismiss 重弹（避免闪烁）。
    @MainActor
    private var updateBinding: Binding<Bool> {
        Binding(
            get: { self.update.shouldPrompt && !self.isDemo },
            set: { _ in /* 强制关不掉；非强制由 center.dismiss() 改变状态 */ }
        )
    }

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
            .task {
                guard !isDemo else { return }   // CI 截图模式不发网络请求
                await update.checkIfNeeded()    // 冷启动检查一次（6 小时节流）
            }
            .sheet(isPresented: updateBinding) {
                UpdateSheet(center: update)
                    // 半屏；强制更新不可拖拽关闭（UpdateSheet 内部还有 interactiveDismissDisabled）
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
            }
        }
    }
}
