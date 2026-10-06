import SwiftUI
import UserNotifications

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

    /// 协议同意状态。**整个 App 最外层的门禁**（见 `body`）：
    /// 没同意时只渲染 `AgreementView`，主界面压根不构造。
    /// 用 `@StateObject` 而不是 `@ObservedObject`：它是 App 生命周期的常驻对象，
    /// 点「同意」后这里一变，`body` 立刻切过去。
    @StateObject private var agreement = AgreementStore.shared

    /// 「同意之后那批冷启动逻辑」只做一次的闸。见 `startServices()`。
    @State private var didStartServices = false

    /// App 在前台 / 后台的状态 —— 回到前台时要把灵动岛的活动接上。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // 提前把用户导入过的字体注册好，免得第一帧找不到字体而回退成系统字体。
        //（协议页自己也要用这套字体，所以它**必须**留在同意之前。）
        _ = FontStore.shared

        // ⚠️ 播放器（`MusicPlayer.shared`）**原来在这里构造** —— 已搬到 `startServices()`：
        //    构造它就会配置 `AVAudioSession` 和远程控制中心，而那属于"用户同意协议
        //    之后才该发生"的事（老板：不同意不准打开，音频会话也不该先起来）。
        //    线程安全性不变：`startServices()` 由 `RootView` 的 `.task` 触发，
        //    一样在主线程上跑，不会退化成后台线程构造。

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

        // ⚠️ 下面这批"要连网 / 开音频 / 开同步"的冷启动逻辑**已经从这里搬走了** ——
        //    它们现在只在**用户同意协议之后**才跑，见 `startServices()`。
        //    （老板 2026-10-06：「不同意不准打开」——那就不该在用户同意前
        //      偷偷去连账号后端、开灵动岛挂机态、接电脑端聊天、把聊天记录传上网盘。）
        //    搬走的是：播放器构造（会开音频会话）、账号后端对齐（`syncEndpoint`）、
        //    灵动岛同步、电脑端聊天通道（`PairChatBridge` / `PairChannel`）、
        //    聊天记录同步（`AutoSync`）。
    }

    var body: some Scene {
        WindowGroup {
            // 🔴 协议门禁 —— **全 App 最外层的一次判断**。
            //
            // 老板 2026-10-06：「打开 app 要同意协议，不同意不准打开」。
            // 没同意时**只**渲染 `AgreementView`：`RootView` 根本不会构造，
            // 于是它上面挂的那些冷启动 `.task` / `.onAppear`（门禁轮询、回前台恢复、
            // 朋友圈补发…）一条都不会跑 —— 这才叫"真的用不了"。
            // 刻意**不用** sheet / fullScreenCover：那种能被下拉划走。
            Group {
                if agreement.accepted {
                    RootView()
                        .environmentObject(personaStore)
                        .environmentObject(settings)
                        .environmentObject(chat)
                        .task { startServices() }
                        .onChange(of: scenePhase) { _, phase in
                            // 回到前台：把灵动岛的活动接上（挂了超过 8 小时就被系统收了，
                            // 得重开一个挂机态）。详见 `LiveIslandCenter.sync()`。
                            guard phase == .active else { return }
                            LiveIslandCenter.shared.sync()
                            // 顺手对一次「远端有没有改接口地址」—— 改完**不用重启 App**，
                            // 切回前台就生效（「不发新包直接切换」）。
                            Task { await AevisApp.applyEndpointOverride() }
                        }
                } else {
                    AgreementView()
                }
            }
            .animation(.easeInOut(duration: 0.28), value: agreement.accepted)
        }
    }

    // MARK: - 同意之后才跑的冷启动

    /// 同意协议之后才跑的、那批"要连网 / 开音频 / 开同步"的冷启动逻辑。
    ///
    /// ⚠️ 原来它们直接写在 `init()` 里 —— 那样**没同意协议也会跑**：
    ///    会去连账号后端、开灵动岛挂机态、接电脑端聊天通道、把聊天记录同步到网盘。
    ///    老板要的是"不同意就不准打开"，那就不能背着用户先把这些做掉。
    ///    ⇒ 搬到这里，由 `RootView` 的 `.task` 触发；而 `RootView` 只有同意了才会被构造。
    ///
    /// ⚠️ `didStartServices` 钉住"整个 App 生命周期只做一次"：
    ///    `.task` 会随视图重建重跑，而下面这些 `start()` 有的挂监听、有的连线路，
    ///    重复跑会重复占资源。
    private func startServices() {
        guard !didStartServices else { return }
        didStartServices = true

        // 播放器是 `@MainActor` 的单例，**先在主线程上把它建出来** ——
        // 不这么做的话，它会在"第一个碰到 MusicPlayer.shared 的线程"上构造，
        // 而那个线程可能是后台（比如音乐工具那条路），于是 `AVAudioSession`
        // 和远程控制中心都会在非主线程被配置。
        //（原在 `init()` 里做；搬家后位置变了，但"主线程"这个前提没变 ——
        //  `.task` 体跑在主线程上。而未同意时它不会被构造 ⇒ 音频会话也不会先起来。）
        _ = MusicPlayer.shared

        // 账号后端：**先拉远端配置，再定线路**。
        // 结果写回 `AppSettings.accountServerURL` —— 各处的接口请求读的都是它，
        // 改这一处全跟着走（`AccountService` / `DeviceGate` / `DiagUploader`）。
        Task { await AevisApp.syncEndpoint() }

        // 冷启动补一次灵动岛（Live Activity）同步 —— 第一次 `scenePhase` 变 active
        // 不一定触发 onChange，所以这里主动补一次，别让挂机态等到切后台才起来。
        Task { @MainActor in LiveIslandCenter.shared.sync() }

        // ⭐ 生态第二期（电脑端聊天）：配过电脑就把那条数据通道接上。
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
