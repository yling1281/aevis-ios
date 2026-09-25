import Foundation

/// QQ 机器人服务：连上 QQ 开放平台的 WebSocket，收到消息就交给她回。
///
/// ## 数据流
/// ```
/// 他在 QQ 里给机器人发一句
///   → 平台把事件推到我们的 WebSocket
///   → 取出发送者 openid + 内容 + 消息 id
///   → 用她的人设跑一次模型（带她的工具）
///   → POST /v2/users/{openid}/messages 回过去（带 msg_id，算被动回复）
/// ```
///
/// ## 为什么必须做「后台保活」
/// 他在 QQ 里跟她聊天时，**我们的 App 正好在后台** —— 而 iOS 会把后台 App 挂起，
/// 连接一断她就哑了。所以这里配了 `SilentKeeper`（后台放一段静音音频），
/// 这是 iOS 上唯一能让 App 长期待在后台的办法。可以在设置里关掉（省电）。
///
/// ⚠️ 这个类**故意不标 `@MainActor`**：WebSocket 的回调、重连的定时任务都在别的线程上，
/// 标了之后到处都要 `await` 跳，很容易在编译上翻车（本机没有 Xcode，一试就是十几分钟）。
/// 所以改成「**状态一律从 `setState` / `setError` 过一道**」——
/// `@Published` 只在主线程上改，界面才不会闪，也不会报 "Publishing changes from background threads"。
final class QQBotService: ObservableObject {

    static let shared = QQBotService()

    // MARK: - 状态

    enum State: Equatable {
        case off
        case connecting
        case online
        case failed(String)

        var label: String {
            switch self {
            case .off: return "没在连"
            case .connecting: return "正在连…"
            case .online: return "在线"
            case .failed(let reason): return "断了：\(reason)"
            }
        }

        var isOnline: Bool { self == .online }
    }

    /// 一条 QQ 上的来往。
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var text: String
        var at: Date
        /// true 表示这条是她发的
        var mine: Bool = false
    }

    @Published private(set) var state: State = .off
    @Published private(set) var botName = ""
    @Published private(set) var received = 0
    @Published private(set) var replied = 0
    @Published private(set) var lastAt: Date?
    @Published private(set) var log: [Line] = []
    @Published var lastError: String?

    /// 只收「群聊 + 私聊」这一类 intent。
    ///
    /// ⚠️ **不能贪多**：多要了平台没给的权限，握手会直接被拒
    /// （SDK 里那个 `DISALLOWED_INTENTS 4915` / `INSUFFICIENT_INTENTS 4914` 就是它）。
    /// 私聊 + 群里 @ 机器人 都归 `GROUP_AND_C2C`（1 << 25）管，够用了。
    private static let intents = 1 << 25

    // MARK: - 内部

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var heartbeat: Task<Void, Never>?
    private var seq: Int?
    private var sessionID: String?
    private var attempt = 0
    private var running = false

    /// 每个会话留一小段上下文 —— 不然她每一句都不记得上一句。
    private var histories: [String: [ChatMessage]] = [:]
    /// 对同一条消息回过几次。**平台限制最多 5 次**，所以得自己数着。
    private var seqByMessage: [String: Int] = [:]

    private init() {}

    // MARK: - 只在主线程改状态
    //
    // 这几个属性是给界面看的（`@Published`），**必须在主线程上改**：
    // 别的线程改会让 SwiftUI 报 "Publishing changes from background threads"，
    // 界面还会闪。收消息的回调、重连的定时任务都在别的线程上，
    // 所以统一从这里过一道，别处不许直接赋值。

    private func setState(_ next: State) {
        if Thread.isMainThread {
            state = next
        } else {
            DispatchQueue.main.async { self.state = next }
        }
    }

    private func setError(_ text: String?) {
        if Thread.isMainThread {
            lastError = text
        } else {
            DispatchQueue.main.async { self.lastError = text }
        }
    }

    var isReady: Bool {
        AppSettings.shared.qqBotEnabled && QQBotClient.shared.isConfigured
    }

    // MARK: - 开关

    func start() async {
        guard !running else { return }
        guard isReady else {
            setState(.off)
            return
        }
        running = true
        attempt = 0
        if AppSettings.shared.qqBotKeepAlive { SilentKeeper.shared.start() }
        await connect(resume: false)
    }

    func stop() {
        running = false
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session = nil
        sessionID = nil
        seq = nil
        setState(.off)
        SilentKeeper.shared.stop()
    }

    /// 回到前台时叫一下：连接要是掉了就重新连上。
    ///
    /// ⚠️ 为什么不能直接调 `start()`：被系统掐掉的时候我们**收不到任何回调**，
    /// `running` 还挂着 true，于是 `start()` 会被「已经在跑」那一句挡住，
    /// 结果就是永远连不上（这种"看起来在跑其实早死了"最难查）。
    func reconnectIfNeeded() {
        guard isReady else { return }
        if state.isOnline, running { return }
        attempt = 0
        if running {
            Task { await connect(resume: false) }
        } else {
            Task { await start() }
        }
    }

    /// 「测试连接」：换一次 token + 问一次机器人自己的信息 + 取一次网关。
    /// 三步都过了才算通 —— 只测 token 是测不出权限问题的。
    func test() async -> String {
        do {
            let token = try await QQBotClient.shared.accessToken(force: true)
            let info = try await QQBotClient.shared.me()
            let gateway = try await QQBotClient.shared.gatewayURL()
            botName = info.name
            return "通了。\n机器人：\(info.name)（\(info.id)）\n"
                + "token 拿到了（\(token.prefix(8))…）\n网关：\(gateway.host ?? "?")"
        } catch {
            return "没通：" + error.localizedDescription
        }
    }

    // MARK: - 连接

    private func connect(resume: Bool) async {
        setState(.connecting)
        do {
            let url = try await QQBotClient.shared.gatewayURL()

            // ⚠️ 每次都必须用一个**新的 session**。
            // 用 `shared` 的话，旧 socket 的取消会牵连新的那条（踩过这种坑）。
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            let newSession = URLSession(configuration: configuration)
            let newSocket = newSession.webSocketTask(with: url)

            session = newSession
            socket = newSocket
            if !resume {
                sessionID = nil
                seq = nil
            }
            newSocket.resume()
            listen()
            setError(nil)
        } catch {
            setState(.failed(error.localizedDescription))
            setError(error.localizedDescription)
            scheduleReconnect()
        }
    }

    /// 收消息 —— `receive` 是「收一条」，所以每收到一条都要再挂一次。
    private func listen() {
        guard let socket else { return }
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error.localizedDescription)
                case .success(let message):
                    self.handleFrame(Self.text(of: message))
                    self.listen()
                }
            }
        }
    }

    private static func text(of message: URLSessionWebSocketTask.Message) -> String {
        switch message {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        default: return ""
        }
    }

    private func handleDrop(_ reason: String) {
        guard running else { return }
        setState(.failed(reason))
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard running else { return }
        heartbeat?.cancel()
        heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil

        attempt += 1
        // 2、4、8、16、32、60 秒 —— 断线不该一直疯敲
        let delay = min(60.0, pow(2.0, Double(min(attempt, 6))))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.running else { return }
            await self.connect(resume: self.sessionID != nil)
        }
    }

    // MARK: - 协议帧

    private func handleFrame(_ raw: String) {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = frame["op"] as? Int else { return }

        if let s = frame["s"] as? Int { seq = s }

        switch op {
        case 10:
            // HELLO：它告诉我心跳该多久一次，然后我表明身份
            let interval = ((frame["d"] as? [String: Any])?["heartbeat_interval"] as? Int) ?? 30000
            startHeartbeat(every: interval)
            if sessionID != nil { resumeSession() } else { identify() }
        case 0:
            guard let type = frame["t"] as? String else { return }
            dispatch(type, (frame["d"] as? [String: Any]) ?? [:])
        case 11:
            break                       // 心跳被确认，什么都不用做
        case 7:
            handleDrop("服务端要求重连")
        case 9:
            sessionID = nil             // 会话失效，重新表明身份
            identify()
        default:
            break
        }
    }

    private func startHeartbeat(every milliseconds: Int) {
        heartbeat?.cancel()
        // 官方 SDK 是每 interval 毫秒发一次；这里留点余量，别贴着上限
        let seconds = max(5.0, Double(milliseconds) / 1000.0 * 0.8)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { break }
                guard let self else { break }
                self.sendFrame(["op": 1, "d": self.seq ?? 0])
            }
        }
    }

    private func identify() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await QQBotClient.shared.accessToken()
                self.sendFrame([
                    "op": 2,
                    "d": [
                        "token": "QQBot \(token)",
                        "intents": Self.intents,
                        "shard": [0, 1],
                        "properties": ["$os": "iOS", "$browser": "aevis", "$device": "aevis"]
                    ]
                ])
            } catch {
                self.setState(.failed(error.localizedDescription))
                self.setError(error.localizedDescription)
            }
        }
    }

    private func resumeSession() {
        guard let sessionID else { identify(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await QQBotClient.shared.accessToken()
                self.sendFrame([
                    "op": 6,
                    "d": ["token": "QQBot \(token)", "session_id": sessionID, "seq": self.seq ?? 0]
                ])
            } catch {
                self.identify()
            }
        }
    }

    private func sendFrame(_ payload: [String: Any]) {
        guard let socket,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: - 事件

    private func dispatch(_ type: String, _ d: [String: Any]) {
        switch type {
        case "READY":
            sessionID = d["session_id"] as? String
            if let user = d["user"] as? [String: Any] {
                botName = (user["username"] as? String) ?? ""
            }
            attempt = 0
            setState(.online)
            setError(nil)
        case "RESUMED":
            attempt = 0
            setState(.online)
        case "C2C_MESSAGE_CREATE", "GROUP_AT_MESSAGE_CREATE", "GROUP_MESSAGE_CREATE":
            Task { await handleIncoming(type, d) }
        default:
            break
        }
    }

    private func handleIncoming(_ type: String, _ d: [String: Any]) async {
        let isPrivate = type == "C2C_MESSAGE_CREATE"
        let author = d["author"] as? [String: Any]
        let name = (author?["username"] as? String)
            ?? (author?["nickname"] as? String)
            ?? "对方"
        let text = (d["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let scope = isPrivate ? "c2c" : "group"
        let target: String? = isPrivate
            ? (author?["user_openid"] as? String)
            : (d["group_openid"] as? String)
        guard let target, !target.isEmpty else { return }

        received += 1
        lastAt = Date()

        guard !text.isEmpty else {
            append(Line(from: name, text: "（这条不是文字，我看不了）", at: Date()))
            return
        }
        append(Line(from: name, text: text, at: Date()))

        guard let reply = await replyText(to: text, scope: scope, target: target, from: name) else {
            return
        }

        let msgID = d["id"] as? String
        do {
            try await QQBotClient.shared.send(
                scope: scope,
                target: target,
                content: reply,
                msgID: msgID,
                msgSeq: nextSeq(for: msgID)
            )
            replied += 1
            append(Line(from: botName.isEmpty ? "她" : botName, text: reply, at: Date(), mine: true))
        } catch {
            setError(error.localizedDescription)
            append(Line(from: "系统", text: "回复没发出去：" + error.localizedDescription, at: Date()))
        }
    }

    private func nextSeq(for msgID: String?) -> Int {
        guard let msgID, !msgID.isEmpty else { return 1 }
        let next = (seqByMessage[msgID] ?? 0) + 1
        // 平台对同一条消息只认 5 次，超了就重来（会被拒，但至少不会一直涨）
        seqByMessage[msgID] = next > 5 ? 1 : next
        if seqByMessage.count > 200 { seqByMessage.removeAll() }
        return next
    }

    // MARK: - 让她回

    private func replyText(to text: String, scope: String, target: String, from name: String) async -> String? {
        let settings = AppSettings.shared
        let persona = PersonaStore.shared.persona
        guard settings.isConfigured, persona.isComplete else {
            setError("模型还没配好，我不知道该怎么回。")
            return nil
        }

        let key = "\(scope):\(target)"
        var history = histories[key] ?? []
        history.append(ChatMessage(role: .user, text: text))
        if history.count > 12 { history.removeFirst(history.count - 12) }

        var memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
        memory.append("现在你在 QQ 上跟他说话（不是在 App 里）。对方叫「\(name)」。"
                      + "回复要短、要像平时发消息那样，别写成一大段。")

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: settings.llm,
                systemPrompt: persona.systemPrompt,
                history: history,
                memory: memory,
                tools: DeviceTools.all()
            ) {
                collected += piece
            }
        } catch {
            setError(error.localizedDescription)
            return nil
        }

        let cleaned = Self.plain(collected)
        guard !cleaned.isEmpty else { return nil }

        history.append(ChatMessage(role: .assistant, text: cleaned))
        histories[key] = history
        return cleaned
    }

    /// QQ 的纯文本消息不认 markdown —— 星号、井号会**原样显示**出来，
    /// 看着像乱码。所以发出去之前先擦干净。
    private static func plain(_ text: String) -> String {
        var out = text
        for junk in ["**", "##", "###", "`", "> "] {
            out = out.replacingOccurrences(of: junk, with: "")
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太长的截一下：一次发一大段在 QQ 上很难看，也没人读完
        if out.count > 900 {
            out = String(out.prefix(900)) + "…"
        }
        return out
    }

    // MARK: - 日志

    private func append(_ line: Line) {
        log.insert(line, at: 0)
        if log.count > 60 { log.removeLast() }
    }

    func clearLog() {
        log = []
        received = 0
        replied = 0
        lastAt = nil
        setError(nil)
    }

    /// 给工具用：最近的消息，**拼成一段纯文字**再交出去。
    ///
    /// 为什么不把 `log` 直接暴露给工具：工具那边不是主线程上下文，
    /// 它拿着这个对象反复跨线程取属性、还要在字符串插值里 `await`，很容易出岔子。
    /// 在这里一次性拼好，那边一个 await 就拿到结果。
    func recentForTools(limit: Int = 20) -> String {
        guard !log.isEmpty else {
            return "QQ 机器人这边还没有任何消息"
                + (state.isOnline ? "。" : "（而且现在没连上：「\(state.label)」）。")
        }
        let body = log.prefix(limit).map { line -> String in
            let who = line.mine ? "我" : line.from
            return "\(Self.clock(line.at)) \(who)：\(line.text)"
        }.joined(separator: "\n")
        return "最近 \(min(log.count, limit)) 条：\n" + body
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
