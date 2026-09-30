import Foundation

/// 卡死看门狗 —— 主线程 5 秒没回心跳就判「冻住」。
///
/// ## 为什么是「主线程心跳」而不是「进程还活着」
/// 音乐 / 天气 / 网络这些异步活不阻塞主线程：进程活着、但界面点不动才是用户嘴里的「卡死」。
/// 所以只测主线程能不能回跳 —— 异步再慢也不会误报。
///
/// ## 阈值
/// 1 秒一测、连续 5 次没心跳 = FROZEN（≥5 秒）。
///
/// ## 检测到之后
/// ① fire-and-forget 上报一次**轻量** freeze（`POST /api/diag` 带 `type=freeze`，
///    不碰黑匣子锁 —— 主线程可能正卡在锁上，这里再取锁等于陪葬）；
/// ② 持久化 `freezePending` 标记，下次启动 `DiagUploader` 用黑匣子富 body 补传并清标记。
///
/// ⚠️ **simulator 直接不启动**（编译条件排除）—— CI 截图脚本反复起 App、又直接 kill，
///    那种「被 kill」会被误判成冻住，后台被刷假报告。
enum Watchdog {

    private static let threshold = 5                 // 连续 5 次（1 秒一次）没心跳 = 冻住
    private static let freezePendingKey = "aevis.watchdog.freezePending"

    private static let lock = NSLock()
    private static var heartbeat = 0                 // 主线程每跳一次 +1
    private static var lastSeen = 0                  // 后台最后一次读到的心跳值
    private static var missed = 0                    // 连续没变的次数
    private static var timer: DispatchSourceTimer?
    private static var fired = false                 // 已经报过，别重复刷

    /// App 启动时调一次（`AevisApp.init`）。
    static func start() {
        #if targetEnvironment(simulator)
        return
        #endif
        if timer != nil { return }

        scheduleBeat()

        let queue = DispatchQueue(label: "aevis.watchdog", qos: .utility)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1, repeating: 1)
        source.setEventHandler { tick() }
        source.resume()
        timer = source
    }

    /// 主线程心跳：1 秒跳一次。主线程真卡住时这一跳也排不上队 —— 正是要抓的信号。
    private static func scheduleBeat() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            lock.lock()
            heartbeat += 1
            lock.unlock()
            scheduleBeat()
        }
    }

    /// 后台串行队列上的定时器，1 秒一测。
    private static func tick() {
        lock.lock()
        let current = heartbeat
        lock.unlock()

        if current == lastSeen {
            missed += 1
        } else {
            lastSeen = current
            missed = 0
        }
        if missed >= threshold {
            fire()
        }
    }

    private static func fire() {
        guard !fired else { return }
        fired = true

        // 持久化标记：下次启动 DiagUploader 用黑匣子富 body 补传。
        UserDefaults.standard.set(true, forKey: freezePendingKey)

        // 轻量上报一次（fire-and-forget）。**不碰黑匣子锁**。
        Task.detached(priority: .utility) {
            await DiagUploader.reportFreezeLight()
        }
    }

    /// 有没有待补传的卡死标记（只读，不清）。
    static func hasFreezePending() -> Bool {
        UserDefaults.standard.bool(forKey: freezePendingKey)
    }

    /// 清掉待补传标记 —— 补传**成功**之后才清，失败留着下次再试。
    static func clearFreezePending() {
        UserDefaults.standard.set(false, forKey: freezePendingKey)
    }
}
