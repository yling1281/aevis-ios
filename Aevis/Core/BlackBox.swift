import Foundation

/// 黑匣子 —— 「刚才到底发生了什么」留在本机上。
///
/// ## 为什么非要有它（被逼出来的）
/// 用户连着报闪退：点歌、通话、网易云搜索。而**我拿不到任何现场** ——
/// 他不会去翻系统日志，本机又没有 Xcode 去复现。前两轮只能读代码猜，猜错过。
///
/// ## 三条血泪教训（都是自己踩的，别改回去）
/// 1. **必须线程安全**。第一版没有锁，而 `NeteaseClient` 的错误分支是从后台线程
///    调 `failure()` 的 —— 和主线程的 `log()` 撞在一起就是
///    `buffer.append` / `buffer.removeFirst` 并发改同一个数组，**堆损坏，随机崩**。
///    现在所有读写都在同一把锁里（`DateFormatter` 也不是线程安全的，一并关进去）。
/// 2. **必须每行立刻落盘**。第二版为了修"卡"，改成攒批（最多延迟 2 秒）——
///    结果**崩溃前那几秒正好没落盘**，而崩溃前那几秒就是全部价值。
///    现在改成往文件末尾**追加一行**（O(1)，不是每次重写 10 KB），
///    既不卡，也保证崩之前每一行都已经在盘上。
/// 3. **不抓崩溃栈**。`NSSetUncaughtExceptionHandler` / `signal` 那套能在崩溃瞬间抓栈，
///    但**在信号处理里做内存分配不是安全操作**（`callStackSymbols` 就会分配）——
///    弄不好引入新的崩溃，而这个 App 本来就在被闪退困扰。
///    记"最后做了什么"便宜得多，而且够用：**闪退几乎总是"上一个动作"引发的**。
///
/// ## 落在哪
/// `Library/Application Support/Aevis/blackbox.log`（不进 Documents ——
/// 那儿以后要开文件共享给用户放字体，日志混进去会让人困惑）。
/// 超过 `maxBytes` 就砍掉前面一半，不会无限长。
enum BlackBox {

    /// 内存里留多少行给界面看。
    private static let limit = 300
    /// 文件超过这个大小就截断（保留最后 `keepOnTrim` 行）。
    private static let maxBytes = 240 * 1024
    private static let keepOnTrim = 800

    private static let runningKey = "aevis.blackbox.running"
    private static let crashKey = "aevis.blackbox.lastCrash"
    private static let crashFlagKey = "aevis.blackbox.hasCrash"

    /// ⚠️ 唯一的锁。`buffer` / `handle` / `formatter` 全在它下面 ——
    /// 少一处就是这个 bug 复发。
    private static let lock = NSLock()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static var buffer: [String] = []
    private static var loaded = false
    private static var handle: FileHandle?
    private static var writtenBytes = 0

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Aevis", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("blackbox.log")
    }

    // MARK: - 生命周期

    /// App 启动时调一次（`AevisApp.init`）。
    static func install() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()

        // ⚠️ 上次没走到 `markCleanExit` 就没了 —— 大概率是崩了
        //（也可能是用户自己上滑划掉的，所以界面上说的是"可能"）。
        let wasRunning = UserDefaults.standard.bool(forKey: runningKey)
        if wasRunning {
            let tail = previousSessionLocked()
            UserDefaults.standard.set(tail, forKey: crashKey)
            UserDefaults.standard.set(true, forKey: crashFlagKey)
        }
        UserDefaults.standard.set(true, forKey: runningKey)

        write("App 启动 v\(Diagnostics.appVersion)")
    }

    /// 正常进后台时调一次。**没调到就说明上次是异常结束的。**
    static func markCleanExit() {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        UserDefaults.standard.set(false, forKey: runningKey)
        write("— 进后台（正常）—")
    }

    // MARK: - 记一笔

    static func log(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        write(text)
    }

    /// 记一次网络失败。
    ///
    /// **URL 和状态码一定要带上** —— 「百度网盘 404」这种问题全靠这一行定位：
    /// 是哪个接口、什么码、服务器说了什么，一眼就能看出来。
    static func failure(_ what: String, url: String? = nil,
                        status: Int? = nil, detail: String? = nil) {
        var line = "❗️\(what)"
        if let status { line += " → HTTP \(status)" }
        if let url { line += "  \(url.prefix(120))" }
        if let detail, !detail.isEmpty { line += "  ⟶ \(detail.prefix(140))" }
        log(line)
    }

    /// 记一次网络成功（只记接口名 + 字节数，不记内容 —— 免得日志里带隐私）。
    static func network(_ what: String, url: String? = nil, bytes: Int? = nil) {
        var line = "· \(what)"
        if let bytes { line += " \(bytes) B" }
        if let url { line += "  \(url.prefix(90))" }
        log(line)
    }

    /// 记一个"接下来要干这件事"的标记。
    ///
    /// 崩溃码是拿**最后一行**算出来的，所以风险动作前面留一句人话，
    /// 用户发来的码才有意义（"又是点歌那一步"而不是"又是某行英文"）。
    static func step(_ text: String) {
        log("▸ \(text)")
    }

    // MARK: - 读出来

    /// 最近这些行（给界面显示）。
    ///
    /// ⚠️ **这里绝不写盘** —— 界面一渲染就会读它，
    /// 在 getter 里做副作用等于每次重绘都写一遍。落盘只在 `log()` 里做。
    static var recent: [String] {
        lock.lock()
        defer { lock.unlock() }
        loadLocked()
        return buffer
    }

    /// 上次异常退出前的那一段（不会被之后的日志冲掉）。
    static var lastCrashLines: [String] {
        UserDefaults.standard.stringArray(forKey: crashKey) ?? []
    }

    /// 上一次是不是异常结束的。
    static var crashedLastRun: Bool {
        UserDefaults.standard.bool(forKey: crashFlagKey)
    }

    /// ⭐ 崩溃码：**同一个故障每次算出同一个码**，用户只要报这 8 位。
    ///
    /// 拿「版本 + 崩前最后一个真正的动作」算 —— 所以它同时是一把定位钥匙：
    /// 十个用户报同一个码 = 卡在同一处，不用挨个要日志。
    static var crashCode: String {
        crashCode(for: lastCrashLines)
    }

    /// 给任意一段记录算码（测试和复用都走这儿，规则只写一份）。
    static func crashCode(for lines: [String]) -> String {
        // 跳过"App 启动"这种噪声，取最后一个**动作**
        let step = lines.last(where: { !$0.contains("App 启动") })
            ?? lines.last ?? "(空)"
        var seed = step
        // 去掉行首时间戳（"HH:mm:ss "）—— 带上它就每次都算成不同的码了
        if seed.count > 9 { seed = String(seed.dropFirst(9)) }
        seed = "v\(Diagnostics.appVersion)|\(seed)"

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(format: "%08X", UInt32(truncatingIfNeeded: hash))
        return "AE-\(hex.prefix(4))-\(hex.suffix(4))"
    }

    /// 攒成一段可以直接发出去的文本。
    static func report() -> String {
        var out = "【Aevis 诊断】\n"
        if crashedLastRun {
            out += "⚠️ 错误码 \(crashCode)  ← 发这个给客服就能定位\n"
        }
        out += "版本 \(Diagnostics.appVersion)  构建 \(Diagnostics.commit)\n"
        out += "系统 iOS \(Diagnostics.osVersion)  机型 \(Diagnostics.machine)\n"
        out += "已签名 \(Diagnostics.isSigned ? "是" : "否")\n"
        out += "设备码 \(DeviceIdentity.pretty)\n"

        if crashedLastRun {
            out += "\n—— 上一次可能异常退出前的那几十步 ——\n"
            let crash = lastCrashLines
            out += crash.isEmpty ? "(没记到)\n" : crash.joined(separator: "\n") + "\n"
        }

        out += "\n—— 最近的运行记录 ——\n"
        out += recent.joined(separator: "\n")
        return out
    }

    /// 清掉（用户自己点的小按钮）。
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer = []
        loaded = true
        writtenBytes = 0
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: crashKey)
        UserDefaults.standard.removeObject(forKey: crashFlagKey)
        write("（记录已清空）")
    }

    /// 用户看完崩溃页之后点"我知道了" —— 只是别再自动弹，记录留着。
    static func acknowledgeCrash() {
        UserDefaults.standard.set(false, forKey: crashFlagKey)
    }

    // MARK: - 内部（**必须在锁里调**）

    private static func write(_ text: String) {
        let line = "\(formatter.string(from: Date())) \(text)"
        buffer.append(line)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
        appendLocked(line + "\n")
    }

    /// 往文件末尾追加。**O(1)**，不是每次重写整个文件 —— 这是"不卡"的关键。
    private static func appendLocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if handle == nil {
            let url = fileURL
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            writtenBytes = (attrs?[.size] as? Int) ?? 0
            _ = try? handle?.seekToEnd()
        }
        do {
            try handle?.write(contentsOf: data)
            writtenBytes += data.count
        } catch {
            // 写盘失败（空间满 / 文件被换掉）→ 丢掉句柄，下一行重开
            handle = nil
            return
        }
        if writtenBytes > maxBytes { trimLocked() }
    }

    /// 文件太大了就只留最后 `keepOnTrim` 行。**不常发生**，所以直接重写没关系。
    private static func trimLocked() {
        let kept = Array(buffer.suffix(keepOnTrim))
        let text = kept.joined(separator: "\n") + "\n"
        try? handle?.close()
        handle = nil
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        writtenBytes = text.utf8.count
        buffer = kept
    }

    /// 上一次会话 = 最后一条"App 启动"之后的所有行。
    ///
    /// 比单纯取末尾 N 行准：用户可能是**隔了很久**才回来导出，
    /// 中间要是又正常用过几次，末尾 N 行早就不是崩的那次了。
    private static func previousSessionLocked() -> [String] {
        guard let start = buffer.lastIndex(where: { $0.contains("App 启动") }) else {
            return Array(buffer.suffix(70))
        }
        return Array(buffer[start...])
    }

    private static func loadLocked() {
        guard !loaded else { return }
        loaded = true
        let url = fileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        writtenBytes = text.utf8.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        buffer = Array(lines.suffix(limit))
    }
}
