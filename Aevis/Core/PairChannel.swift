import Foundation

/// 手机 ↔ 电脑的**数据长连**（生态第二期：电脑端聊天）。
///
/// ## 它是什么
/// 配对服务（`server/pair/server.py`）那条 WS，除了推 `paired` / `peer` / `revoked`，
/// 还认一种 `relay`：**把 `data` 原样转给对端，服务器不解释、不存储**。
/// 电脑端聊天就架在它上面 —— 所以**不用打洞、也不用先做局域网直连**，跨网也能用。
///
/// ## 🔴 三条口径（别对外说错）
/// 1. **不是端到端加密**：信封是明文 JSON，服务器**看得见**内容（它只是不存）。
///    加密那一层还没做，见 `topics/ecosystem.md`。
/// 2. 只连**最近配对的那一台**电脑（`PairClient.paired.first`）。
/// 3. 断了自动重连（指数退避，封顶 30 秒）—— 切后台、换 WiFi 都会断。
///
/// ## ⚠️ 为什么单开一个 `URLSession`
/// `URLSession.shared` 上还挂着账号接口、相册上传那些请求；WS 的 delegate 队列
/// 跟它们混在一起不好排查。这里单开一个，配置也只为自己。
///
/// ## ⚠️ 地址永远是 `ws://`
/// 配对服务器**没有证书、没有 nginx**（腾讯云 `106.52.113.18:9100`）—— 所以别想当然
/// 写 `wss://`，那是连不上的。`Info.plist` 里已经放开了明文。
///
/// ## ⭐ 连的是「配对时那台电脑」，不是公网那台（2026-10-03）
/// 电脑版现在**默认自己当服务器**（局域网直连）⇒ 地址跟着 `PairClient` 里记的
/// 那台电脑走（见 `base(for:)`）。局域网里那台是 `http://192.168.x.x:9100`，
/// 公网模式配的才是腾讯云 —— **两种都在同一段代码里，靠记录的地址区分**。
final class PairChannel: NSObject, ObservableObject {

    static let shared = PairChannel()

    enum State: Equatable {
        case off            // 没配对 / 主动关掉
        case connecting     // 正在连（含重连等待）
        case online         // 连上了
    }

    /// 通道状态（界面上的小圆点用它）。
    @Published private(set) var state: State = .off
    /// 对面那台电脑叫什么（状态行显示"已连上 xxx"）。
    @Published private(set) var pcName: String = ""

    /// 现在连的是哪一台（`PairClient.paired` 里的 session）。没连就是 nil。
    var currentSession: String? { session }

    /// 电脑发来的一包数据（`relay` 里的 `data`）。
    /// ⚠️ **在 WS 的后台队列上回调** —— 要碰界面请自己跳主线程。
    var onPayload: (([String: Any]) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: String?
    private var pingTimer: Timer?
    private var retry = 0
    private var wantOn = false

    private lazy var urlSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private override init() { super.init() }

    // MARK: - 开关

    /// App 启动时叫一下：**配过电脑就自动连上**，没配过就什么也不做。
    func autoStart() {
        guard let pc = PairClient.paired.first else { return }
        start(session: pc.session, pcName: pc.name)
    }

    /// 配对成功后调它（`PairScanView` 那边）。
    func start(session: String, pcName: String) {
        wantOn = true
        self.pcName = pcName
        if self.session == session, task != nil { return }
        self.session = session
        retry = 0
        connect()
    }

    /// 用户解除配对 / 关掉开关。
    func stop() {
        wantOn = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
        pcName = ""
        state = .off
    }

    // MARK: - 发

    /// 给电脑发一包数据（自动套上 `{"t":"relay"}` 信封）。
    func send(_ payload: [String: Any]) {
        guard let task, let text = Self.text(["t": "relay", "data": payload]) else { return }
        // 失败也不报错：断了自己会重连，用户不需要知道中间掉过一次。
        task.send(.string(text)) { _ in }
    }

    // MARK: - 连接

    private func connect() {
        guard wantOn, let session else { return }
        let base = Self.base(for: session)
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        guard let url = URL(string: base + "/ws?role=phone&session=" + session) else { return }

        state = .connecting
        let task = urlSession.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen(task)
        armPing()
    }

    /// 该连哪台 —— **配对时那台电脑**，不是写死在包里的公网地址。
    ///
    /// 🔴🔴 这是「电脑端走局域网」最后的一步（2026-10-03）。
    ///   电脑版现在默认**自己当服务器**：那张码里的 `h` 是路由器给的
    ///   `192.168.x.x`，session 也只存在**那台电脑**上。
    ///   要是这里还按老的 `PairClient.currentBase`（腾讯云那台）去连：
    ///     · 那台服务器**根本没有这个 session** ⇒ 握手直接 401；
    ///     · 这里把失败当"网断了、等会儿重连" ⇒ 变成**无限重连**，
    ///       界面上就是一个永远转圈的小圆点，而且**一点都不报错**。
    ///   ⚠️ 老记录（记之前配的）没有地址 ⇒ 老实地退回 `currentBase`，
    ///      这样才能既支持局域网、又不动已经配好的用户。
    static func base(for session: String) -> String {
        if let pc = PairClient.paired.first(where: { $0.session == session }),
           let base = pc.base {
            return base
        }
        return PairClient.currentBase
    }

    private func listen(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.dropped()
            case .success(let message):
                self.handle(message)
                self.listen(task)          // 继续等下一帧
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = json["t"] as? String else { return }

        switch kind {
        case "hello":
            retry = 0
            DispatchQueue.main.async { self.state = .online }
        case "relay":
            if let payload = json["data"] as? [String: Any] { onPayload?(payload) }
        default:
            break            // pong / whoami 之类不关心
        }
    }

    private func dropped() {
        pingTimer?.invalidate()
        pingTimer = nil
        task = nil
        guard wantOn else {
            DispatchQueue.main.async { self.state = .off }
            return
        }
        DispatchQueue.main.async { self.state = .connecting }
        let delay = min(30.0, pow(2.0, Double(retry)))
        retry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// 每 20 秒发一个应用层 ping。
    /// ⚠️ 服务端有"对端一直没反应就断"的机制（`WS_IDLE_STRIKES`），不发会被它清掉。
    private func armPing() {
        pingTimer?.invalidate()
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.send(["k": "ping"])
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    // MARK: - 零件

    private static func text(_ obj: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
