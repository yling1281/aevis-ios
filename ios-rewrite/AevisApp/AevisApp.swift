import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var session = Session.shared
    /// 更新门禁：挂在 root 外层，force 时盖住登录页 / 主界面。
    /// shared 单例用 ObservedObject 即可（生命周期由单例自己管）。
    @ObservedObject private var update = AppUpdateCenter.shared

    /// 冷启动上飘动效：进程启动时 false → onAppear 弹到 true，只飘一次。
    /// 切后台回来 root 不重建，所以不会再飘。
    @State private var appeared = false

    /// 前后台状态（2026-11-24）：回到 `.active` 时再查一次更新，
    /// 这样用户从后台切回来也能看到「强制更新」，不必杀掉进程重开。
    @Environment(\.scenePhase) private var scenePhase

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

    /// 正常入口：冷启动校验先占位（避免闪一下主界面），没登录去登录页，登录了进主 TabBar。
    @ViewBuilder private var root: some View {
        if session.validating {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.token == nil {
            LoginView()
        } else {
            MainTabView()
                // 冷启动上飘：只在这里（已登录根视图）挂，进程启动飘一次
                .offset(y: appeared ? 0 : 24)
                .opacity(appeared ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.05)) {
                        appeared = true
                    }
                }
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
            // 全局背景（2026-11-25）：垫在**所有**页面最底层，登录页 / 主界面 /
            // 商城 / 会员 / 广场 / 聊天全都透出同一张图。之前只在 MainTabView 里挂了一份，
            // 登录页和部分全屏页没有背景，用户切页会看到「背景没了」。
            // 这里只负责铺背景，不加任何底色；页面内一律用 glassCard 半透明材质。
            AppBackgroundHost {
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
            }
            .environmentObject(session)
            // 跟随设置页的「外观」三档（themeMode）——挂在根视图上，全 App 一起变
            .modifier(ThemeModeModifier())
            .task {
                guard !isDemo else { return }        // CI 截图模式不发网络请求
                // 恢复直连的一次性迁移：老用户 apiLineId=bj / apiFailedLines 含 direct 时，
                // 重置到直连并清掉旧失败标记（只做一次，之后用户手动选择优先）。
                APIClient.migrateToDirectIfNeeded()
                // 冷启动**强制**查一次（无视节流），保证「进程刚起就一定检查强更」。
                await update.checkIfNeeded(force: true)
                // 协议内容热更新：本地硬缓存先显示，云端有新版本才覆盖（失败保留旧缓存）。
                await AgreementContentStore.shared.checkAndUpdateAll()
            }
            // 回到前台（含从后台切回）也查一次 —— 受 30 分钟节流约束，避免频繁请求。
            // 之前只在冷启动查 + 6 小时节流，「切走再切回」进程没重启就永远不查 → 强更不弹。
            .onChange(of: scenePhase) { phase in
                guard !isDemo else { return }
                if phase == .active {
                    Task { await update.checkIfNeeded() }
                }
            }
            .sheet(isPresented: updateBinding) {
                UpdateSheet(center: update)
                    // 半屏；强制更新不可拖拽关闭（UpdateSheet 内部还有 interactiveDismissDisabled）
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
                    // 磨砂玻璃弹窗：让 sheet 背景透明，背后聊天界面才能透出模糊感。
                    // 强制更新仍由 binding 的空 set + interactiveDismissDisabled 双重保证关不掉。
                    .glassSheetBackground()
            }
        }
    }
}

// MARK: - 全局外观

/// 外观三档（`themeMode` 0 跟随系统 / 1 浅色 / 2 深色），与设置页共用同一个 AppStorage 键。
///
/// 2026-11-22：原来 `preferredColorScheme` 只写在 `SettingsView` 自己身上，
/// 设置里切浅色/深色只有设置页变、别处不变，等于假开关。提到根视图（这里）才对全 App 生效：
/// 用 ViewModifier 而不是在 `App` 上挂 @AppStorage，保证切档位时这一层会重新求值。
private struct ThemeModeModifier: ViewModifier {
    @AppStorage("themeMode") private var themeMode = 0

    func body(content: Content) -> some View {
        content.preferredColorScheme(
            themeMode == 1 ? .light : (themeMode == 2 ? .dark : nil)
        )
    }
}
