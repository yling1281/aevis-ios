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

        // 账号后端：**先拉远端配置，再定线路**。
        // 结果写回 `AppSettings.accountServerURL` —— 各处的接口请求读的都是它，
        // 改这一处全跟着走（`AccountService` / `DeviceGate` / `DiagUploader`）。
        Task { await AevisApp.syncEndpoint() }

        // 冷启动补一次灵动岛（Live Activity）同步 —— 第一次 `scenePhase` 变 active
        // 不一定触发 onChange，所以这里主动补一次，别让挂机态等到切后台才起来。
        Task { @MainActor in LiveIslandCenter.shared.sync() }

        // ⭐ 生态第二期（电脑端聊天）：配过电脑就把那条数据通道接上。
        // ⚠️ 放在 `init` 里而不是 `.onAppear` —— SwiftUI 的 onAppear 会随视图重建
        //    反复触发，而这两件事要的是"整个 App 生命周期只做一次"。
        // 没配过电脑的话它俩**什么也不做**（不建连接、不占资源）。
        PairChatBridge.shared.start()
        PairChannel.shared.autoStart()

        // ⭐ 聊天记录自动同步到百度网盘（2026-10-03 老板要的三件事）。
        //
        // `start()` 只做一件永久的事：在 `ChatStore` 上挂一个"又落了一条消息"的监听
        // ⇒ 每说一句话就把聊天记录传上网盘（去抖几秒，见 `AutoSync.quiet`）。
        // 真正的搬运**不在这里做** —— 见 `RootView` 里 `scenePhase` 那两行。
        //
        // ⚠️ 条件不满足时（没登录 / 没连网盘 / 开关关了）它只是把状态标成"没在同步"，
        //    不会去连网、不会去读聊天记录。
        AutoSync.shared.start()
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
                    // 顺手对一次「远端有没有改接口地址」—— 改完**不用重启 App**，
                    // 切回前台就生效（「不发新包直接切换」）。
                    Task { await AevisApp.applyEndpointOverride() }
                }
        }
    }

    // MARK: - 接口地址
    //
    // 两个静态方法，主 App / 启动路径共用一份口径，别在别处再拼一遍。

    /// 启动时对齐一次接口地址：**先拉远端配置，再定线路**。
    ///
    /// ⚠️ 顺序不能反：远端配置里的 `accountBase` 优先级最高（见
    ///    `AevisHosts.remoteOverrideKey`），而它得先从远端拿下来；
    ///    反过来的话每次启动都先按编译进去的地址跑一轮，要**下次启动**才切过去。
    /// ⚠️ 写 `AppSettings` 那一步必须回主线程 —— 它不是 `@MainActor`，
    ///    在后台改 `@Published` 会让 SwiftUI 在别的线程收到变更通知（iOS 26 直接崩，踩过）。
    /// ⚠️ 远端拉不到、线路全探不通都**不抛错、不挡启动**：`refresh()` 会退回编译进去
    ///    那个地址，行为跟以前一样。
    static func syncEndpoint() async {
        await RemoteConfig.shared.refresh()
        let base = await AccountEndpoint.refresh()
        let current = await MainActor.run { AppSettings.shared.accountServerURL }
        if base != current {
            await MainActor.run { AppSettings.shared.accountServerURL = base }
        }
    }

    /// 回前台时只做一件事：**远端把接口地址改了没有**。
    ///
    /// ⚠️ 故意**不**在这里重新探测线路 —— 网络抖一下就把用户手动选的线路改掉，
    ///    那是帮倒忙。启动那次探测已经够了，用户还能在设置里点「换线」。
    static func applyEndpointOverride() async {
        await RemoteConfig.shared.refresh()
        guard let remote = AccountEndpoint.remoteOverride() else { return }
        let current = await MainActor.run { AppSettings.shared.accountServerURL }
        guard remote != current, await AccountEndpoint.reachable(remote) else { return }
        await MainActor.run { AppSettings.shared.accountServerURL = remote }
    }
}
