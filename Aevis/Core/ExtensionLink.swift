import Foundation
import Network

/// 主 App 与「系统录屏扩展」之间的**第二条通道**。
///
/// ## 为什么需要第二条
/// iOS 给两个进程的**官方**共享方式只有 App Group 容器（见 `ScreenShareStore`）。
/// 但我们的 IPA 是在手机上用第三方工具重签的 —— 那份描述文件里的
/// 「应用程序组」如果不包含我们请求的那几个，**扩展那边的容器就是 nil**：
/// 它照样收得到画面、认得出字，却一个字都送不回来。
///
/// 症状就长这样：**系统弹出的列表里明明有「Aevis 录屏」、红点也亮了，
/// 她却始终说看不到屏幕。** 用户就是这么报的，而且光看包和配置完全正常。
///
/// ## 这条是什么
/// 扩展往 `127.0.0.1` 的一个固定端口 POST 一小段 JSON，主 App 在那头听着。
/// 环回地址**不出这台手机**、不需要局域网权限、也不依赖任何签名能力。
///
/// 两条通道都留着：
/// - 容器能用就走容器（**扩展退出之后还能翻到历史**）；
/// - 容器不能用还有这条（至少当下看得见）。
/// 两边都发也不会重复 —— 主 App 合并时会按内容去重。
///
/// 这个文件**同时编进两个 target**，所以端口、格式只有一份定义。
enum ExtensionLink {

    /// 固定端口。两边都从这里取，不许各写各的。
    static let port: UInt16 = 53127

    static var endpoint: URL? {
        URL(string: "http://127.0.0.1:\(port)/ingest")
    }

    enum Kind: String, Codable {
        /// 一条「她看到的」。
        case entry
        /// 「在录 / 停了」+ 统计。
        case state
    }

    struct Payload: Codable {
        var kind: Kind
        var text: String?
        var running: Bool?
        var frames: Int?
        var hits: Int?
        var at: Double

        static func entry(_ text: String) -> Payload {
            Payload(kind: .entry, text: text, running: nil,
                    frames: nil, hits: nil, at: Date().timeIntervalSince1970)
        }

        static func state(running: Bool, frames: Int, hits: Int) -> Payload {
            Payload(kind: .state, text: nil, running: running,
                    frames: frames, hits: hits, at: Date().timeIntervalSince1970)
        }
    }

    // MARK: - 发（扩展那边用）

    /// 把一小段数据送回主 App。
    ///
    /// **故意做成「发完不管」**：录屏是附带功能，不能让一条网络请求
    /// 把整个扩展拖住或者搞崩。主 App 没在跑的时候这里就是连不上，静默失败。
    static func post(_ payload: Payload) {
        guard let endpoint, let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}

/// 主 App 侧的接收端。App 活着的时候才有用，所以随根视图起。
///
/// 收的东西**只放内存**：它管的是「此刻能看到什么」，
/// 历史由容器那份管（容器不可用时历史也就没有，这是必然的）。
final class ExtensionLinkListener {

    static let shared = ExtensionLinkListener()

    /// 收到一条「她看到的」。
    var onEntry: ((String, Date) -> Void)?
    /// 收到一次状态上报（在录 / 停了 + 帧数 + 认出次数 + 时刻）。
    var onState: ((Bool, Int, Int, Date) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "aevis.extension-link")

    private init() {}

    /// 幂等：重复调用不会起两个。
    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: ExtensionLink.port) else { return }
        guard let created = try? NWListener(using: .tcp, on: port) else { return }

        created.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        created.stateUpdateHandler = { [weak self] state in
            // 端口被占之类：安静放弃，App 其余部分照常。
            if case .failed = state { self?.stop() }
        }
        created.start(queue: queue)
        listener = created
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 在不在听。诊断里要说清楚这件事。
    var isListening: Bool {
        listener != nil
    }

    // MARK: - 收

    private func accept(_ connection: NWConnection) {
        // ⚠️ 这个端口在「只听本机」这件事上没法靠参数保证，所以自己挡一道：
        // 只收环回地址发来的。否则同一个 WiFi 上的人也能往她「看到的」里塞东西。
        if case let .hostPort(host, _) = connection.endpoint {
            let name = "\(host)"
            guard name.hasPrefix("127.") || name == "::1" else {
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        read(connection, accumulated: Data())
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }

            if let body = Self.body(of: buffer) {
                self.deliver(body)
                Self.reply(connection)
                return
            }
            if error != nil || isComplete || buffer.count > 256 * 1024 {
                connection.cancel()
                return
            }
            self.read(connection, accumulated: buffer)
        }
    }

    private func deliver(_ body: Data) {
        guard let payload = try? JSONDecoder().decode(ExtensionLink.Payload.self, from: body)
        else { return }
        let date = Date(timeIntervalSince1970: payload.at)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch payload.kind {
            case .entry:
                guard let text = payload.text, !text.isEmpty else { return }
                self.onEntry?(text, date)
            case .state:
                self.onState?(payload.running ?? false,
                              payload.frames ?? 0,
                              payload.hits ?? 0,
                              date)
            }
        }
    }

    // MARK: - 极简 HTTP

    /// 从一个已经读到的字节流里取出 body。还没读全就返回 nil，让调用方接着读。
    private static func body(of data: Data) -> Data? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let header = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        var length = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            guard parts[0].lowercased() == "content-length" else { continue }
            length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }

        let start = separator.upperBound
        guard data.distance(from: start, to: data.endIndex) >= length else { return nil }
        return data.subdata(in: start..<data.index(start, offsetBy: length))
    }

    private static func reply(_ connection: NWConnection) {
        let text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
