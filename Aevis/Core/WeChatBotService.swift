import Foundation

/// 微信机器人（腾讯官方 ClawBot / iLink 通道）—— 扫码绑定 + 长轮询收消息。
///
/// ## 这条为什么和 QQ 那条完全不是一个做法
/// `QQBotService` 是**在 Swift 里直接开 WebSocket**；微信这条**整个跑在 App 里
/// 那个真 Linux（iSH / Alpine）里** —— 扫码、取码、35 秒长轮询全在 guest 的一个
/// 后台进程里，宿主只干两件事：**把命令发进去、把文件读回来**。
///
/// 为什么非要这样（老板 2026-10-06 的原话）：
/// 「微信的扫码的话，要本地的，就是不经过电脑和服务器。它不是有 Linux 控制台吗？用 Linux」
/// 也就是说：**不经过我们的账号服务器、也不经过任何一台电脑**，扫码绑定和收发消息
/// 都落在这台手机上。
///
/// ## iSH 的硬特性（照做，别绕）
/// · 命令被包进**子 shell** 跑 ⇒ `cd` / `export` 不跨命令；没有 PTY ⇒ guest 脚本不许读 stdin。
/// · `nohup … &` 会**立即返回** ⇒ 长轮询只能「后台化 + 重定向到文件 + 宿主反复读文件」。
/// · 🔴 **绝不用前台阻塞循环跑长任务**：`aevis_ish_wait` 超时后只能 `abort_current`，
///   那会把 shell 判脏、只能重启 App。见 `AlpineRuntime` 顶部那一段。
///
/// ## iOS 上做不到的部分（必须说清楚，别让人以为坏了）
/// · **App 被系统挂起时，guest 里的后台进程也一起停** —— 这是 iOS 的硬限制，
///   只能靠 `SilentKeeper`（后台放静音音频）尽量拖住。真被挂了，回到前台要靠
///   `reconnectIfNeeded()` 重新把轮询器拉起来。
/// · 没有 history / getMessages 接口 ⇒ 只能看「绑定之后、用户↔bot」这一条会话。
///
/// ## 线程口径
/// ⚠️ 这个类**故意不标 `@MainActor`**（和 `QQBotService` 一样）：它的调用点散在
/// 后台任务里，标了之后到处都要 `await` 跳，本机没 Xcode、一试就是一轮 CI。
/// 改成「**一切 `@Published` 都从 `setXxx` 过一道**」—— 只有它们碰界面状态，
/// 于是不会报 "Publishing changes from background threads"，iOS 26 上也不会硬崩。
final class WeChatBotService: ObservableObject {

    static let shared = WeChatBotService()

    // MARK: - 状态

    enum State: Equatable {
        case off
        case probing
        case ready
        case waitingScan
        case bound
        case polling
        case frozen(String)
        case failed(String)

        var label: String {
            switch self {
            case .off: return "没在跑"
            case .probing: return "正在忙…"
            case .ready: return "自检跑完了"
            case .waitingScan: return "出码了，等你扫"
            case .bound: return "已绑定"
            case .polling: return "已绑定，正在收消息"
            case .frozen(let why): return "被冻结了：\(why)"
            case .failed(let why): return "出错了：\(why)"
            }
        }

        var isBound: Bool {
            switch self {
            case .bound, .polling, .frozen: return true
            case .off, .probing, .ready, .waitingScan, .failed: return false
            }
        }
    }

    /// 一项自检的**真实结果**。命令原文、输出原文都照存，界面直接显示，不做任何美化。
    struct ProbeResult: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var command: String
        var output: String
        var ok: Bool
    }

    /// 从 getupdates 里读出来的一条来往。
    struct Incoming: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var text: String
        var at: Date
    }

    @Published private(set) var state: State = .off
    @Published private(set) var probes: [ProbeResult] = []
    @Published private(set) var qrPayload: String?
    @Published private(set) var incoming: [Incoming] = []
    @Published private(set) var received = 0
    @Published var lastError: String?

    // MARK: - 只在主线程改 @Published
    //
    // 非隔离的 async 函数在 `await` 之后**线程是随机的**；在那儿改 `@Published`
    // 会让 SwiftUI 报 "Publishing changes from background threads"、iOS 26 上更会硬崩
    // （见 swift_check 的 R29）。所以统一从这里过一道，别处不许直接赋值。

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func setState(_ next: State) { onMain { self.state = next } }
    private func setProbes(_ next: [ProbeResult]) { onMain { self.probes = next } }
    private func setQR(_ next: String?) { onMain { self.qrPayload = next } }
    private func setIncoming(_ next: [Incoming]) { onMain { self.incoming = next } }
    private func setReceived(_ next: Int) { onMain { self.received = next } }
    private func setError(_ next: String?) { onMain { self.lastError = next } }

    // MARK: - guest 里的固定位置（和 wechat_bind.sh 的约定一一对应）

    private enum Guest {
        static let dir = "/root/wechat"
        static let script = "/root/wechat/wechat_bind.sh"
        static let qrcode = "/root/wechat/qrcode.json"
        static let status = "/root/wechat/status.json"
        static let updates = "/root/wechat/updates.jsonl"
        static let ticket = "/root/wechat/ticket.txt"
        static let token = "/root/wechat/token.txt"
        static let uin = "/root/wechat/uin.txt"
        static let frozen = "/root/wechat/frozen"
        static let stop = "/root/wechat/stop"
        static let keepalive = "/root/wechat/keepalive.txt"
    }

    /// 宿主侧的状态（**不是** `@Published`，界面不直接读）。
    private var polling = false
    private var readOffset = 0
    private var readerTask: Task<Void, Never>?

    private init() {}

    var isReady: Bool { AppSettings.shared.weChatBotEnabled }

    /// 一句能直接显示在界面上的绑定摘要。
    var boundSummary: String {
        let settings = AppSettings.shared
        guard settings.weChatBotBoundAt > 0 else { return "还没绑定" }
        let date = Date(timeIntervalSince1970: settings.weChatBotBoundAt)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let id = settings.weChatBotILinkID.isEmpty ? "（没拿到 bot id）" : settings.weChatBotILinkID
        return "已绑定 · \(id) · " + formatter.string(from: date)
    }

    // MARK: - 唯一碰 iSH 的入口

    /// 所有碰 iSH 的命令**只从这一条路走**，而且锁在 `#if !targetEnvironment(simulator)` 里。
    ///
    /// ⚠️ 为什么必须锁：`libaevisish.a` **只有真机切片**（见 project.yml 的
    ///    `OTHER_LDFLAGS[sdk=iphoneos*]`），模拟器那条线根本不链它 —— 只要有一个
    ///    调用表达式逃出 `#if`，模拟器链接就会缺符号、CI 直接红。
    ///    真机上则把命令交给 `AlpineRuntime`（全工程唯一调 C 的地方，它自己会 boot）。
    private func linux(_ command: String) async -> CommandResult {
        #if targetEnvironment(simulator)
        return .fail("模拟器里没有内置 Linux（只有装到真机上才有）。")
        #else
        return await AlpineRuntime.shared.run(command)
        #endif
    }

    /// 把脚本写进 guest（每次启动都覆盖写一遍），并 `chmod +x`。
    ///
    /// 为什么用 base64 传：脚本里有 `$` / 引号 / `$(( ))` 数学括号，直接内联进
    /// shell 命令会被**宿主 shell 和 guest shell 各展开一次**，迟早出事；
    /// base64 出来只有 A–Z a–z 0–9 + / =，怎么转都安全，顺带也绝不会撞上
    /// `run` 禁止的哨兵串 `__AEVIS_RC__=`（base64 字母表里没有下划线）。
    private func installScript() async -> CommandResult {
        guard let text = bundledScriptText() else {
            return .fail("安装包里没找到 ish-scripts/wechat_bind.sh。")
        }
        let encoded = Data(text.utf8).base64EncodedString()
        let command = "mkdir -p \(Guest.dir) && "
            + "printf '%s' '\(encoded)' | base64 -d > \(Guest.script) && "
            + "chmod 755 \(Guest.script) && echo AEVIS_SCRIPT_OK"
        return await linux(command)
    }

    /// 从 App 包里读脚本。`ish-scripts` 是**文件夹引用**（project.yml 里 `type: folder`），
    /// 所以按 `Bundle/ish-scripts/wechat_bind.sh` 取 —— 同 `AlpineRuntime` 取 rootfs 的写法。
    private func bundledScriptText() -> String? {
        let dir = Bundle.main.url(forResource: "ish-scripts", withExtension: nil)
            ?? Bundle.main.bundleURL.appendingPathComponent("ish-scripts", isDirectory: true)
        let file = dir.appendingPathComponent("wechat_bind.sh")
        return try? String(contentsOf: file, encoding: .utf8)
    }

    // MARK: - 自检（三件事的真实探针）

    /// 三项自检。**如实**：每一步都把命令原文和输出原文存下来，界面直接显示。
    /// 没拿到就说没拿到，绝不编造任何状态或数字。
    func probe() async {
        setError(nil)
        setState(.probing)
        var results: [ProbeResult] = []

        // 0) 先把脚本放进 guest（自检本身也要靠它把 curl 装上）。
        let install = await installScript()
        results.append(ProbeResult(
            title: "0 · 把脚本放进内置 Linux",
            command: "base64 解码写入 \(Guest.script) 并 chmod 755",
            output: install.output.trimmingCharacters(in: .whitespacesAndNewlines),
            ok: install.output.contains("AEVIS_SCRIPT_OK")))

        // 1) 出网：iSH 里到底能不能访问外网 HTTPS。
        let netCommand = "sh \(Guest.script) install >/dev/null 2>&1; "
            + "curl -sS -m 10 -o /dev/null -w '%{http_code}' https://ilinkai.weixin.qq.com 2>&1"
        let net = await linux(netCommand)
        results.append(ProbeResult(
            title: "1 · 出网（在 iSH 里打一次 iLink）",
            command: netCommand,
            output: net.output.trimmingCharacters(in: .whitespacesAndNewlines),
            ok: Self.looksLikeHTTPCode(net.output)))

        // 2) 后台作业：nohup 立即返回，20 秒后往文件里写 alive。
        let jobCommand = "rm -f /tmp/aevis_probe; "
            + "nohup sh -c 'sleep 20; echo alive > /tmp/aevis_probe' >/dev/null 2>&1 &"
        let job = await linux(jobCommand)
        results.append(ProbeResult(
            title: "2 · 后台作业（立即返回，20 秒后看结果）",
            command: jobCommand,
            output: job.output.isEmpty
                ? "已发出（nohup 立刻返回了，退出码 \(job.exitCode)）。过 20 秒点「看结果」。"
                : job.output,
            ok: job.exitCode == 0))

        // 3) 保活：每秒往文件里记一行，靠行数增长判断后台有没有被 iOS 连锅端。
        let keepCommand = "rm -f \(Guest.keepalive); "
            + "nohup sh -c 'i=0; while true; do i=$((i+1)); echo $i >> \(Guest.keepalive); sleep 1; done' "
            + ">/dev/null 2>&1 &"
        let keep = await linux(keepCommand)
        results.append(ProbeResult(
            title: "3 · 保活（每秒记一行，看后台有没有被挂起）",
            command: keepCommand,
            output: keep.output.isEmpty
                ? "已启动。把 App 退到后台 2 分钟再回来，点「看结果」看行数涨没涨。"
                : keep.output,
            ok: keep.exitCode == 0))

        setProbes(results)
        setState(.ready)
    }

    /// 自检的「看结果」：把第 2、3 项的真实文件读回来，替换掉那两条的输出。
    func recheckBackground() async {
        var results = probes
        guard results.count >= 4 else { return }

        let job = await linux("cat /tmp/aevis_probe 2>&1")
        let jobText = job.output.trimmingCharacters(in: .whitespacesAndNewlines)
        results[2].output = jobText.isEmpty
            ? "文件还是空的 —— 后台那条 sleep 20 要么还没到点，要么被 iOS 挂起了。"
            : "文件里有：" + jobText
        results[2].ok = jobText.contains("alive")

        let keep = await linux("wc -l < \(Guest.keepalive) 2>&1")
        let keepText = keep.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepLines = Int(keepText) ?? 0
        results[3].output = keepLines > 0
            ? "现在有 \(keepLines) 行。记下这个数，过一会儿再看它涨没涨 —— 涨了说明 guest 还活着。"
            : "读不到计数（\(keepText)）。保活脚本可能没起来。"
        results[3].ok = keepLines > 0

        setProbes(results)
    }

    // MARK: - 扫码绑定

    /// 扫码绑定：取码 → 交给界面画码 → 轮询状态 → 成功就把 token 等存起来。
    func startBind() async {
        setError(nil)
        setState(.probing)

        let install = await installScript()
        guard install.output.contains("AEVIS_SCRIPT_OK") else {
            setError("脚本没能放进内置 Linux：" + install.output)
            setState(.failed("脚本没写进去"))
            return
        }

        _ = await linux("sh \(Guest.script) qrcode >/dev/null 2>&1")
        let body = (await linux("cat \(Guest.qrcode) 2>/dev/null")).output
        guard let obj = Self.jsonObject(body),
              let ticket = obj["qrcode"] as? String, !ticket.isEmpty else {
            setError("没拿到二维码。iSH 返回的原文：\n" + (body.isEmpty ? "（空）" : body))
            setState(.failed("取码失败"))
            return
        }

        // 票交给 guest 落地（base64 走，免得出特殊字符）—— status 用它查。
        let ticketB64 = Data(ticket.utf8).base64EncodedString()
        _ = await linux("printf '%s' '\(ticketB64)' | base64 -d > \(Guest.ticket)")

        setQR(ticket)
        setState(.waitingScan)

        // 轮询扫码状态：最多等 5 分钟，每 2 秒一次（**不刷屏**）。
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if Task.isCancelled { return }
            _ = await linux("sh \(Guest.script) status >/dev/null 2>&1")
            let statusBody = (await linux("cat \(Guest.status) 2>/dev/null")).output
            if let status = Self.jsonObject(statusBody),
               let token = status["bot_token"] as? String, !token.isEmpty {
                await saveBinding(from: status, token: token)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        setError("等了 5 分钟还没扫上。二维码可能过期了，重新点一次「微信扫码绑定」。")
        setState(.failed("扫码超时"))
    }

    /// 绑定成功后落地：token 走钥匙串、bot id / 时间走 UserDefaults、token 写进 guest。
    @MainActor
    private func saveBinding(from status: [String: Any], token: String) async {
        let settings = AppSettings.shared
        settings.weChatBotToken = token
        settings.weChatBotILinkID = (status["ilink_bot_id"] as? String) ?? ""
        settings.weChatBotBoundAt = Date().timeIntervalSince1970

        let uin = (status["ilink_user_id"] as? String) ?? ""
        _ = await writeGuest(settings.weChatBotToken, to: Guest.token)
        _ = await writeGuest(uin, to: Guest.uin)
        // 新绑定 ⇒ 旧的增量游标作废（换了个 bot，游标对不上）。
        _ = await linux("rm -f \(Guest.updates) \(Guest.frozen) \(Guest.stop)")

        setQR(nil)
        setState(.bound)
        await startPolling()
    }

    /// 解绑：只删本地 token（**还要去微信侧解绑**，界面里会提醒）。
    @MainActor
    func unbind() async {
        await stopPolling()
        _ = await linux("rm -f \(Guest.token) \(Guest.uin) \(Guest.stop) \(Guest.frozen)")
        let settings = AppSettings.shared
        settings.weChatBotToken = ""
        settings.weChatBotILinkID = ""
        settings.weChatBotBoundAt = 0
        setQR(nil)
        setState(.off)
    }

    // MARK: - 后台长轮询

    /// 起长轮询。🔴 **单轮询者**：同一个 bot 只能有一个轮询者（游标存在轮询者本地，
    /// 多起一个就会互相抢游标、把 `get_updates_buf` 弄乱），所以在跑就**不重复起**。
    func startPolling() async {
        guard !polling else { return }
        let settings = AppSettings.shared
        guard !settings.weChatBotToken.isEmpty else {
            setError("还没绑定（没有 token），绑上再收消息。")
            return
        }

        let install = await installScript()
        guard install.output.contains("AEVIS_SCRIPT_OK") else {
            setError("脚本没能放进内置 Linux：" + install.output)
            return
        }

        // token / uin 再写一遍（App 重启、或换了绑定之后要保证对得上）。
        _ = await writeGuest(settings.weChatBotToken, to: Guest.token)
        _ = await writeGuest(settings.weChatBotILinkID, to: Guest.uin)
        _ = await linux("rm -f \(Guest.frozen) \(Guest.stop)")

        // 从「当前文件末尾」开始读 —— 免得把上一个会话的消息又刷一遍。
        let sizeText = (await linux("wc -c < \(Guest.updates) 2>/dev/null || echo 0")).output
        readOffset = Self.firstInt(sizeText) ?? 0

        // 🔴 长轮询只许这样起：nohup … & + 重定向到文件，绝不在前台阻塞。
        let launch = await linux("nohup sh \(Guest.script) poll > \(Guest.dir)/poll.out 2>&1 &")
        if launch.exitCode != 0 {
            setError("轮询器没起来：" + launch.output)
            setState(.failed("轮询器没起来"))
            return
        }

        startReader()
        polling = true
        setState(.polling)
    }

    /// 停长轮询：落一个 stop 标记，guest 循环下一圈就退出。
    func stopPolling() async {
        _ = await linux("mkdir -p \(Guest.dir); : > \(Guest.stop)")
        readerTask?.cancel()
        readerTask = nil
        polling = false
        if state.isBound { setState(.bound) }
    }

    /// 回到前台时叫一下：轮询器可能被 iOS 连 App 一起挂起了，确认它还活着。
    ///
    /// ⚠️ 不能直接调 `startPolling()` 而不看状态 —— 被挂起时我们**收不到任何回调**，
    ///    `polling` 还可能挂着 true，于是会被「已经在跑」那句挡住、永远起不来
    ///    （这种「看起来在跑其实早死了」最难查，QQ 那边踩过）。所以这里先补读一次。
    func reconnectIfNeeded() {
        guard AppSettings.shared.weChatBotEnabled else { return }
        guard !AppSettings.shared.weChatBotToken.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            if self.polling {
                await self.readOnce()
            } else {
                await self.startPolling()
            }
        }
    }

    /// 宿主侧的读取循环：每 3 秒读一次文件。
    private func startReader() {
        readerTask?.cancel()
        readerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await self?.readOnce()
            }
        }
    }

    /// 读一次：先看有没有「冻结」标记，再增量读 `updates.jsonl`。
    @MainActor
    private func readOnce() async {
        // 冻结：guest 探测到 ret=-14 会写这个文件并退出循环。
        let frozenText = (await linux("cat \(Guest.frozen) 2>/dev/null")).output
        if !frozenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await stopPolling()
            setError("账号被冻结了（ret=-14）。iLink 的说法是冻 1 小时、没有 refresh，"
                     + "只能重新扫码。原文：\n" + frozenText)
            setState(.frozen("ret=-14，要重新扫码"))
            return
        }

        // 增量读 updates.jsonl：只取本次新增的字节。
        let sizeText = (await linux("wc -c < \(Guest.updates) 2>/dev/null || echo 0")).output
        let size = Self.firstInt(sizeText) ?? 0
        guard size > readOffset else { return }
        let chunk = (await linux("tail -c +\(readOffset + 1) \(Guest.updates)")).output
        readOffset = size

        var added: [Incoming] = []
        for line in chunk.split(separator: "\n") {
            guard let obj = Self.jsonObject(String(line)) else { continue }
            added.append(contentsOf: Self.messages(from: obj))
        }
        guard !added.isEmpty else { return }

        let existing = incoming
        setIncoming(added.reversed() + existing)   // 新的排在上面
        setReceived(existing.count + added.count)
    }

    func clearIncoming() {
        setIncoming([])
        setReceived(0)
        setError(nil)
    }

    // MARK: - 小工具

    /// 把一段文本 base64 落地到 guest 的某个文件（免得出特殊字符）。
    private func writeGuest(_ text: String, to path: String) async -> CommandResult {
        let encoded = Data(text.utf8).base64EncodedString()
        return await linux("printf '%s' '\(encoded)' | base64 -d > \(path)")
    }

    /// 把一段文本当 JSON 解；解不出返回 nil（**不抛**，由调用方决定怎么显示原文）。
    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return value as? [String: Any]
    }

    /// 输出里末尾那个 HTTP 码像不像 2xx / 3xx。
    private static func looksLikeHTTPCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(separator: "\n").last,
              let code = Int(last.trimmingCharacters(in: .whitespaces)) else { return false }
        return code >= 200 && code < 400
    }

    /// 取开头的连续数字（`wc -c` 会带前导空格，这里顺手去掉）。
    private static func firstInt(_ text: String) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0.isNumber }
        return Int(digits)
    }

    /// 从一个 getupdates 响应里抠出消息。
    ///
    /// ⚠️ 我们手上**没有 iLink 的权威字段表**，所以这里把几个常见的容器名 / 字段名
    ///    都试一遍；认不出就不硬编造消息（宁可漏，不可假）。真出现新形状，
    ///    把整条原文摆出来的地方在 `readOnce`（`lastError` / `updates.jsonl`）。
    private static func messages(from obj: [String: Any]) -> [Incoming] {
        let containers = ["msgs", "msg_list", "updates", "messages", "list"]
        var items: [[String: Any]] = []
        for key in containers {
            if let list = obj[key] as? [[String: Any]] {
                items = list
                break
            }
        }
        guard !items.isEmpty else { return [] }

        var out: [Incoming] = []
        for item in items {
            let from = (item["from_user_name"] as? String)
                ?? (item["from"] as? String)
                ?? (item["sender"] as? String)
                ?? (item["user_name"] as? String)
                ?? "对方"
            let text = (item["content"] as? String)
                ?? (item["text"] as? String)
                ?? (item["msg"] as? String)
                ?? (item["message"] as? String)
                ?? ""
            guard !text.isEmpty else { continue }
            out.append(Incoming(from: from, text: text, at: Date()))
        }
        return out
    }
}
