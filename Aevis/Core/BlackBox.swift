import Foundation

/// 黑匣子 —— 「刚才到底发生了什么」留在本机上。
///
/// ## 为什么非要有它（被逼出来的）
/// 用户连着报闪退：点歌、通话、网易云搜索。而**我拿不到任何现场** ——
/// 他不会去翻系统日志，本机又没有 Xcode 去复现。前两轮只能读代码猜，猜错过。
///
/// 这里记三样东西，都是低成本、一定能拿到的：
/// 1. **每一步关键操作**（时间 + 动作）
/// 2. **网络请求失败**连 URL 和状态码一起记 —— 「百度网盘莫名 404」这类全靠它定位
/// 3. **上一次是不是异常退出**（没走到 `markCleanExit` 就没了）
///
/// 用户在「设置 → 关于」里一键复制发过来，现场就齐了。
///
/// ## 为什么不去抓崩溃栈
/// `NSSetUncaughtExceptionHandler` / `signal` 那套能在崩溃瞬间抓栈，但
/// **在信号处理里做任何内存分配都不是安全操作**（`callStackSymbols` 就会分配）——
/// 弄不好引入新的崩溃，而这个 App 本来就在被闪退困扰。
/// 记"最后做了什么"便宜得多，而且够用：**闪退几乎总是"上一个动作"引发的**。
enum BlackBox {

    /// 最多留多少行。够还原最近几十步，又不会把 UserDefaults 撑大（约 10 KB）。
    private static let limit = 150
    private static let linesKey = "aevis.blackbox.lines"
    private static let runningKey = "aevis.blackbox.running"
    private static let crashKey = "aevis.blackbox.lastCrash"
    private static let crashFlagKey = "aevis.blackbox.hasCrash"

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 进程内的缓冲 —— 省掉反复从 UserDefaults 读。
    private static var buffer: [String] = []
    private static var loaded = false

    // MARK: - 生命周期

    /// App 启动时调一次（`AevisApp.init`）。
    static func install() {
        ensureLoaded()

        // ⚠️ 上次没走到 `markCleanExit` 就没了 —— 大概率是崩了
        //（也可能是用户自己上滑划掉的，所以界面上说的是"可能"）。
        // 把最后那几十行单独存一份：它不会被之后的正常日志冲掉。
        if UserDefaults.standard.bool(forKey: runningKey) {
            UserDefaults.standard.set(Array(buffer.suffix(70)), forKey: crashKey)
            UserDefaults.standard.set(true, forKey: crashFlagKey)
        }
        UserDefaults.standard.set(true, forKey: runningKey)
        persist()

        log("App 启动 v\(Diagnostics.appVersion)")
    }

    /// 正常进后台时调一次。**没调到就说明上次是异常结束的。**
    static func markCleanExit() {
        UserDefaults.standard.set(false, forKey: runningKey)
        persist()
    }

    // MARK: - 记一笔

    static func log(_ text: String) {
        ensureLoaded()
        buffer.append("\(formatter.string(from: Date())) \(text)")
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
        // 每次都落盘。**故意不攒批** —— 崩在攒批中间丢掉的恰好是最关键的那几行。
        persist()
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

    // MARK: - 读出来

    /// 最近这些行（给界面显示）。
    ///
    /// ⚠️ **这里绝对不能写盘** —— 界面一渲染就会读它，
    /// 在 getter 里做副作用等于每次重绘都写一遍 UserDefaults（10 KB）。
    /// 落盘的事交给 `log()`。
    static var recent: [String] {
        ensureLoaded()
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

    /// 攒成一段可以直接发出去的文本。
    static func report() -> String {
        var out = "【Aevis 诊断】\n"
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
        buffer = []
        loaded = true
        UserDefaults.standard.removeObject(forKey: linesKey)
        UserDefaults.standard.removeObject(forKey: crashKey)
        UserDefaults.standard.removeObject(forKey: crashFlagKey)
        persist()
        log("（记录已清空）")
    }

    // MARK: - 内部

    private static func ensureLoaded() {
        guard !loaded else { return }
        buffer = UserDefaults.standard.stringArray(forKey: linesKey) ?? []
        loaded = true
    }

    private static func persist() {
        guard loaded else { return }
        UserDefaults.standard.set(buffer, forKey: linesKey)
    }
}
