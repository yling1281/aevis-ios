import SwiftUI
import UserNotifications

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

    /// App 在前台 / 后台的状态 —— 回到前台时要把灵动岛的活动接上。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 提前把用户导入过的字体注册好，免得第一帧找不到字体而回退成系统字体。
        _ = FontStore.shared

        // ⚠️ 播放器是 `@MainActor` 的单例，**在 init 里就把它建出来**。
        // 不这么做的话，它会在"第一个碰到 MusicPlayer.shared 的线程"上构造 ——
        // 而那个线程可能是后台（比如音乐工具那条路），于是 AVAudioSession
        // 和远程控制中心都会在非主线程被配置。这里先钉死在主线程。
        _ = MusicPlayer.shared

        // 黑匣子：记下"上一次是怎么结束的"。**必须最早调** ——
        // 越早开始记，越能抓到启动阶段的问题。
        // （它也是被逼出来的：用户连着报闪退，而我拿不到任何现场。）
        BlackBox.install()

        // 只在 Debug 构建、且带了 -aevisDemo 启动参数时才写入演示数据，
        // 供 CI 在模拟器里截图自检用。正式使用完全不受影响。
        DemoSeed.applyIfRequested()

        // 崩过的话，把现场传给服务器一次（后台按错误码能查到）。
        // 不 await —— 启动路径上不干等网络；传不上去也没关系，本机那份还在。
        Task { await DiagUploader.uploadCrashIfNeeded() }

        // 卡死看门狗：主线程 5 秒没回心跳 = 冻住（simulator 自动跳过）。
        // 检测到会轻量上报一次 freeze，并把标记留到下次启动补传富 body。
        Watchdog.start()

        // 上次若卡死过，这里用黑匣子富 body 补传一次（成功后清标记）。
        // 不 await —— 跟崩溃上报一样，不挡启动路径。
        Task { await DiagUploader.uploadFreezeIfNeeded() }

        // 通知代理：App 正在前台时，那条通知要**当场落进聊天记录**、不弹横幅
        // （用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的」）。
        // ⚠️ 必须在这里设：`UNUserNotificationCenter` 的 delegate 是**弱引用**，
        //    存成局部变量的话当场就没了，回调永远不会来。
        UNUserNotificationCenter.current().delegate = ProactiveNotificationDelegate.shared

        // 通知分类：横幅上那个「回一句」的输入框靠它。
        // ⚠️ 分类是**跟系统注册**的（不是跟单条通知走的），所以启动时就得注册一次 ——
        //    漏了这一步，通知上根本不会出现打字框（而且不报错，只是悄悄没有）。
        ProactiveService.registerCategories()

        // 账号后端有主域名 + 备用域名（拦截是按线路抽样的，谁通走谁）。
        // 结果写回 `AppSettings.accountServerURL` —— 各处读的都是它，改一处全跟着走。
        // ⚠️ 必须回到主线程再写：`AppSettings` 不是 `@MainActor`，在后台改 `@Published`
        //    会让 SwiftUI 在别的线程上收到变更通知（iOS 26 上直接崩，踩过）。
        Task {
            let base = await AccountEndpoint.refresh()
            await MainActor.run { AppSettings.shared.accountServerURL = base }
        }

        // 远端配置：开机拉一次（**不 await、不挡启动**，失败就安静用缓存）。
        // 这是「不出新包也能改开关」那条路 —— 详见 `RemoteConfig`。
        Task { await RemoteConfig.shared.refresh() }

        // 冷启动补一次灵动岛（Live Activity）同步 —— 第一次 `scenePhase` 变 active
        // 不一定触发 onChange，所以这里主动补一次，别让挂机态等到切后台才起来。
        Task { @MainActor in LiveIslandCenter.shared.sync() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
                .onChange(of: scenePhase) { _, phase in
                    // 回到前台：把灵动岛的活动接上（挂了超过 8 小时就被系统收了，
                    // 得重开一个挂机态）。详见 `LiveIslandCenter.sync()`。
                    guard phase == .active else { return }
                    LiveIslandCenter.shared.sync()
                }
        }
    }
}
