import Foundation

#if canImport(Darwin)
import Darwin
#endif

// ============================================================================
// AlpineRuntime —— 把 iSH 那套嵌入式 Linux 内核，从 App 里驱动起来
// ----------------------------------------------------------------------------
// 这是全工程**唯一**会去调 `aevis_ish_*`（C 接口）的地方。所有调用表达式都锁在
// `#if !targetEnvironment(simulator)` 里，理由见下面「为什么必须这样切」。
//
// ## 契约从哪来
// 唯一的契约是 `ish_embed.h`（出包 CI 从固定 tag `ish-vendor` 取回，解到
// `vendor/ish/`），经桥接头 `AevisIshBridge.h` 暴露给 Swift。它只提供
// int / const char * / char * 三种类型，没有任何 struct。App 侧一行 C 都不编 ——
// iSH 的源码已经编进 `libaevisish.a` 了（再往里加 .c 必然 duplicate symbol）。
//
// ## 一次性（写死在 iSH 里，绕不过）
// · 一个进程**只能成功 boot 一次**：iSH 的全局状态（mount 表、pid 表、
//   signal handler……）是进程级的，重复 boot 只会返回「已经 boot 过」。
// · 内核一旦死了**不能重启** —— 所谓「重启」只能靠用户把整个 App 杀掉重开。
//   所以超时后强掐（abort）等于把这套内核判死，之后只能重启 App 恢复。
//
// ## 坑 3：boot 之后 App 自己的 stdout 会串进 guest 输出（已知、本轮不修）
// `aevis_ish_boot` 会把**宿主进程**的 fd 0/1/2（以及 printk 用的 fd 666）
// 重定向到内部管道，好让 guest 的 fd 0/1/2 通到我们这边。副作用是：
// boot 之后再往 stdout 打东西（Swift 的 print()、NSLog 的一部分），会掉进
// 那条管道、被当成 **guest 输出**读走 —— 表现就是「命令台里冒出一些不该有的行」。
// 目前的处置是：**App 里不要往 stdout 打印**（本项目日志一律走 BlackBox）。
// 这里**故意不做** freopen 把 stdout 接到 /dev/null：那会让宿主与 guest 的
// fd 1 指向同一个底层管道，处理不当会把 guest 输出一起弄坏。真要根治得由
// 内核侧把「宿主重定向」和「guest 管道」彻底分开，那是另一件事。
//
// ## 为什么必须把调用切在 `#if !targetEnvironment(simulator)` 里
// `libaevisish.a` 只有 iphoneos/arm64 切片（见 project.yml 的
// `OTHER_LDFLAGS[sdk=iphoneos*]`）—— 模拟器那条线**不链**它。
// 桥接头只暴露「声明」，**可见不等于引用**；只要有一个调用表达式逃出 `#if`，
// 模拟器链接就会缺符号、CI 直接红（而 CI 的截图唯一就是从模拟器那步产出的）。
// 所以本文件里：所有 `aevis_ish_*` 调用、以及会触碰它们的私有方法，
// 全部只在 `#if !targetEnvironment(simulator)` 分支里存在。
// 对外暴露的属性（phase / isUsable / statusText）只读纯 Swift 状态，绝不在这里调 C。
// ============================================================================

/// Alpine 运行时的阶段（**纯 Swift 状态**，界面只读它，里面绝不调 C）。
enum AlpineRuntimePhase: Equatable {
    /// 还没开始（第一次用到才会启动）。
    case notStarted
    /// 正在把 rootfs 准备到可写目录。
    case preparing
    /// 正在启动内核。
    case booting
    /// 就绪，可以收命令了。
    case ready
    /// 启动失败（本进程内不能再试）。
    case failed(String)
    /// 内核已废（超时强掐或内核 die），只能重启 App。
    case dead(String)
}

/// 真 Alpine（iSH）运行时。所有 C 调用都在这一个类里，且都在**一条串行队列**上。
final class AlpineRuntime {

    static let shared = AlpineRuntime()

    /// 所有 iSH 的 C 调用都排在这一条队列上，**绝不并发** ——
    /// `run` / `wait` / `take_output` 之间必须严格有序。
    private let queue = DispatchQueue(label: "com.aevis.alpine", qos: .userInitiated)

    private let lock = NSLock()
    private var phaseStore: AlpineRuntimePhase = .notStarted

    private init() {}

    // MARK: - 对外只读状态（任何线程可读；**这里绝不调 C**）

    /// 当前阶段。
    var phase: AlpineRuntimePhase {
        lock.lock()
        let value = phaseStore
        lock.unlock()
        return value
    }

    /// 这套 Alpine 现在能不能被选来用。
    ///
    /// 语义：**只要还没被永久判死就是 true** —— 包括「还没启动」和「正在启动」。
    /// 详细理由见 `AlpineShell.isAvailable` 上面的注释（一句话：命令台的 provider
    /// 是视图初始化那一刻取下来的，这里若要求「必须已 boot 完」，内部 Linux
    /// 就永远起不来）。
    var isUsable: Bool {
        switch phase {
        case .failed, .dead:
            return false
        case .notStarted, .preparing, .booting, .ready:
            return true
        }
    }

    /// 一句话状态说明，直接拿去显示（**诚实**：把已知限制都写清楚）。
    var statusText: String {
        switch phase {
        case .notStarted:
            return "真 Linux（Alpine），跑在 App 里。第一次用会自动启动，可能要十几秒。命令之间不共享 cd / export；需要键盘输入的程序（vi、passwd）用不了。"
        case .preparing:
            return "正在准备 Alpine 的运行环境（首次会把它解到可写目录，稍等）…"
        case .booting:
            return "正在启动 Alpine 内核…"
        case .ready:
            return "真 Linux（Alpine），跑在 App 里。命令之间不共享 cd / export；需要键盘输入的程序（vi、passwd）用不了。"
        case .failed(let reason):
            return "这次没能启动：\(reason)"
        case .dead(let reason):
            return "内核已经废了：\(reason)。重启 App 才能恢复。"
        }
    }

    // MARK: - 跑一条命令

    /// 跑一条命令。默认给足超时（这类命令可能很慢）。
    ///
    /// **为什么是 4 分钟**：底层契约给的分档是「普通命令 5–15 秒；装包 / 下载 / 编译
    /// 120–300 秒」，所以取一个覆盖得住慢命令、又不至于让用户干等太久的中间值。
    /// **宁可给足，不要给太小** —— 因为超时的代价很重：
    ///
    /// ⚠️ `aevis_ish_wait` 超时**不会**自动收尾，只能靠 `aevis_ish_abort_current()`
    ///    强行收场，而那会把这套内核判成「脏」。而这个内核是**一次性**的
    ///    （一个进程只能 boot 一次、内核死了不能重启）⇒ 用户只能**重启 App**。
    ///    所以调大这个值比调小安全。
    ///
    /// ⚠️ 模拟器上永远返回一句「没有内置 Linux」—— 不在模拟器上碰任何 C。
    func run(_ command: String, timeoutMs: Int = 240_000) async -> CommandResult {
        #if targetEnvironment(simulator)
        return .fail("模拟器里没有内置 Linux（只有装到真机上才有）。")
        #else
        return await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult, Never>) in
            queue.async {
                continuation.resume(returning: self.performRun(command, timeoutMs: timeoutMs))
            }
        }
        #endif
    }

    // MARK: - 写状态（串行队列 / 主线程都可能调，统一加锁）

    private func setPhase(_ next: AlpineRuntimePhase) {
        lock.lock()
        phaseStore = next
        lock.unlock()
    }

    // ========================================================================
    // 真机实现 —— 从这里到本类末尾那个 #endif 之前，全部只在真机上编。
    // 所有 `aevis_ish_*` 调用都在这个区间里。
    // ========================================================================
    #if !targetEnvironment(simulator)

    /// 与 `ish_embed.h` 的返回码一一对应（**故意在 Swift 侧重写一份**，
    /// 不依赖 C 宏能否被 Swift 导入 —— 这些数值是对外协议的一部分，不能漂）。
    private enum IshResult {
        static let ok: Int32 = 0
        static let errArg: Int32 = -1
        static let errAlready: Int32 = -2
        static let errRootfs: Int32 = -3
        static let errMount: Int32 = -4
        static let errBoot: Int32 = -5
        static let errTimeout: Int32 = -6
        static let errDead: Int32 = -7
    }

    /// rootfs 准备失败用的错误（把中文说明包成 `localizedDescription`）。
    private struct RuntimeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 在串行队列上跑：确保已 boot，然后发命令 → 等结束 → 收输出。
    private func performRun(_ command: String, timeoutMs: Int) -> CommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ok("") }

        if let failure = ensureBooted() {
            return failure
        }

        // 上一条要是还在跑（理论上不会，队列是串行的），先把它等完再发。
        if aevis_ish_busy() != 0 {
            let waitRC = aevis_ish_wait(Int32(timeoutMs))
            if waitRC == IshResult.errTimeout {
                return abortAfterTimeout(timeoutMs: timeoutMs)
            }
        }

        let runRC = trimmed.withCString { aevis_ish_run($0) }
        if runRC != IshResult.ok {
            let note = lastMessageText()
            if runRC == IshResult.errDead {
                setPhase(.dead(note.isEmpty ? "内核不再接受命令" : note))
            }
            return .fail("这条命令没发出去（\(note.isEmpty ? "未知原因" : note)）。")
        }

        let waitRC = aevis_ish_wait(Int32(timeoutMs))
        if waitRC == IshResult.errTimeout {
            return abortAfterTimeout(timeoutMs: timeoutMs)
        }
        if waitRC != IshResult.ok {
            let note = lastMessageText()
            _ = takeAndFreeOutput()               // 顺手把还没读走的输出丢掉（内部已 free）
            return .fail("等这条命令结束时出了岔子（\(note.isEmpty ? "未知原因" : note)）。")
        }

        let output = takeAndFreeOutput()
        let exitCode = Int(aevis_ish_last_exit_code())
        if output.isEmpty && exitCode != 0 {
            // 命令失败了又没有输出 —— 至少别让它看起来像成功。
            let note = lastMessageText()
            return CommandResult(output: note.isEmpty ? "命令返回了非 0 退出码：\(exitCode)" : note,
                                 exitCode: exitCode)
        }
        return CommandResult(output: output, exitCode: exitCode)
    }

    /// 确保已经 boot。返回 nil 表示就绪；返回非 nil 表示直接失败、别再往下走。
    private func ensureBooted() -> CommandResult? {
        switch phase {
        case .ready:
            return nil
        case .failed(let reason):
            return .fail("Alpine 没能启动：\(reason)")
        case .dead(let reason):
            return .fail("Alpine 内核已经废了：\(reason)。重启 App 才能恢复。")
        case .notStarted, .preparing, .booting:
            break
        }

        setPhase(.preparing)
        let rootfsPath: String
        do {
            rootfsPath = try prepareRootfs()
        } catch {
            let reason = error.localizedDescription
            setPhase(.failed(reason))
            return .fail("Alpine 的运行环境准备失败：\(reason)")
        }

        setPhase(.booting)
        let bootRC = boot(rootfsPath: rootfsPath, tmpPath: prepareTmpDir())
        if bootRC != IshResult.ok {
            let reason = bootFailureText(rc: bootRC)
            setPhase(.failed(reason))
            return .fail("Alpine 内核启动失败：\(reason)")
        }
        setPhase(.ready)
        return nil
    }

    // MARK: - 对 C 的调用（**只有这几个**，全在真机分支里）

    /// `rootfsPath` 传的是 **`data/` 的父目录**（不是 `data/` 本身）。
    private func boot(rootfsPath: String, tmpPath: String) -> Int32 {
        rootfsPath.withCString { root in
            tmpPath.withCString { tmp in
                aevis_ish_boot(root, tmp)
            }
        }
    }

    /// 取走增量输出。⚠️ 返回的是 `malloc` 出来的内存，**必须由我们 free**。
    private func takeAndFreeOutput() -> String {
        guard let raw = aevis_ish_take_output() else { return "" }
        defer { free(raw) }
        return String(cString: raw)
    }

    /// 最近一次内部错误说明（永远非 NULL，不需要 free）。
    private func lastMessageText() -> String {
        guard let raw = aevis_ish_last_message() else { return "" }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bootFailureText(rc: Int32) -> String {
        let note = lastMessageText()
        if !note.isEmpty { return note }
        switch rc {
        case IshResult.errRootfs:  return "rootfs 目录不对（缺 data 或 meta.db）"
        case IshResult.errMount:   return "挂载 rootfs 失败"
        case IshResult.errBoot:    return "内核起进程失败"
        case IshResult.errAlready: return "这个进程已经启动过一次 Alpine 了"
        case IshResult.errTimeout: return "启动超时"
        default:                   return "未知错误（\(rc)）"
        }
    }

    /// 超时处置：**如实说**，并把内核判死（不再假装能用）。
    private func abortAfterTimeout(timeoutMs: Int) -> CommandResult {
        _ = aevis_ish_abort_current()             // 把 busy 清掉，同时把 shell 判脏
        let partial = takeAndFreeOutput()
        let seconds = max(1, timeoutMs / 1000)
        setPhase(.dead("有条命令跑了 \(seconds) 秒还没结束"))
        var text = partial
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "这条命令跑了 \(seconds) 秒还没结束，已经强行掐掉。内核状态可能已被污染 —— 之后如果命令都跑不动，重启 App 才能恢复。"
        return CommandResult(output: text, exitCode: 124)
    }

    // MARK: - rootfs 准备（纯文件操作，不碰 C）

    private func prepareRootfs() throws -> String {
        let fm = FileManager.default

        let bundled = bundledRootfsURL()
        guard fm.fileExists(atPath: bundled.path) else {
            throw RuntimeFailure(message: "安装包里没有 Alpine 的 rootfs。")
        }

        // ⚠️ 包里那份是**只读**的，必须拷到 App 可写位置再 boot。
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let target = support.appendingPathComponent("ish-rootfs", isDirectory: true)

        // ⚠️ 只在「目标不存在」或「版本文件不同」时才重拷 ——
        //    这样 guest 自己装的东西（apk add 装上的包）重启 App 后还在。
        let targetExists = fm.fileExists(atPath: target.path)
        let bundledVersion = readTrimmed(bundled.appendingPathComponent(".version"))
        let targetVersion = readTrimmed(target.appendingPathComponent(".version"))
        var needCopy = false
        if !targetExists {
            needCopy = true
        } else if let bundledVersion, bundledVersion != targetVersion {
            needCopy = true
        }

        if needCopy {
            if targetExists {
                try? fm.removeItem(at: target)
            }
            try? fm.createDirectory(at: support, withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: bundled, to: target)
            } catch {
                throw RuntimeFailure(message: "拷贝 rootfs 失败：\(error.localizedDescription)")
            }
        }

        // ⚠️ 拷完必须校验形状：<target>/data 是目录、<target>/meta.db 是文件。
        var isDir: ObjCBool = false
        let dataPath = target.appendingPathComponent("data", isDirectory: true)
        guard fm.fileExists(atPath: dataPath.path, isDirectory: &isDir), isDir.boolValue else {
            throw RuntimeFailure(message: "rootfs 里缺 data 目录（拷贝没成功？）。")
        }
        var isFileDir: ObjCBool = false
        let metaPath = target.appendingPathComponent("meta.db")
        guard fm.fileExists(atPath: metaPath.path, isDirectory: &isFileDir), !isFileDir.boolValue else {
            throw RuntimeFailure(message: "rootfs 里缺 meta.db（拷贝没成功？）。")
        }

        return target.path
    }

    private func bundledRootfsURL() -> URL {
        if let url = Bundle.main.url(forResource: "ish-rootfs", withExtension: nil) {
            return url
        }
        return Bundle.main.bundleURL.appendingPathComponent("ish-rootfs", isDirectory: true)
    }

    private func readTrimmed(_ url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// iSH 要把 Unix socket 前缀放在可写目录（iOS 上 guest 的 /tmp 不可写）。
    private func prepareTmpDir() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("ish-tmp", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    #endif
}
