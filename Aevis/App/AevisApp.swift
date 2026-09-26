import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

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
