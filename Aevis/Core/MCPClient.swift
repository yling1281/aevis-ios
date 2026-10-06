import Foundation

/// 一个 MCP 服务器的配置。
///
/// 「MCP」是让ta的能力可以**外接**的一种方式：你电脑上跑一个 MCP 服务器
/// （能读文件、能查数据库、能操作别的东西），Aevis 连上去，
/// 那边提供什么工具，ta就多几只手 —— 不用改一行 App 代码。
struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    /// 额外的请求头，一行一个「名字: 值」。
    /// 需要认证的服务就填 `Authorization: Bearer xxx` 这种。
    var headerLines: String = ""
    var enabled: Bool = true

    /// 如果是「Aevis 电脑助手」带进来的，顺手记下它的主机和端口。
    ///
    /// 「配对手机」那一段要拿这两个值去调 `/phone.json`。从 `url` 反解也能做，
    /// 但用户手改过地址（加了路径、换了写法）之后就会解错，不如存下来。
    /// 手动添加的普通 MCP 服务这里就是空的 —— 界面上靠它决定要不要显示手机那一段。
    var pcHost: String = ""
    var pcPort: Int = 0

    /// 这条是不是电脑助手带进来的（能不能显示「配对手机」）。
    var looksLikePC: Bool { !pcHost.isEmpty && pcPort > 0 }

    /// 这台设备到底是**一台电脑**，还是一个**普通的 MCP 服务器**。
    ///
    /// 用户 2026-10-02 明确要求：「不是所有设备都是电脑，你要识别这个是不是电脑」。
    /// 判定**只看它是不是由「Aevis 电脑助手」配对进来的** —— 那一步会在
    /// `PCAgent.serverConfig` 里把 `pcHost` / `pcPort` 填上（见 `MCPStore.addComputer`）。
    /// 手动添加的普通 MCP（米家那种智能家居服务、别的第三方服务）这两个字段一直是空的，
    /// 所以一律是 `.server`，**绝不会**被当成一台电脑。
    ///
    /// 为什么不把 `kind` 存成一个字段：它的值完全由 `pcHost` / `pcPort` 推得，
    /// 存下来就多一个要落盘的字段 —— 还得**同步改上面那个手写的 `init(from:)`**，
    /// 漏一个字段老数据就整条解不出来（得不偿失）。做成计算属性，零成本、也不会不同步。
    enum Kind {
        /// 由「Aevis 电脑助手」配对进来的电脑。
        case computer
        /// 手动添加的普通 MCP 服务器（不是电脑）。
        case server
    }

    /// `looksLikePC` 的「显式版」：把「是不是电脑」直接说成一个类型，
    /// 界面按它选图标、选标签，而不是各自去拼一个 Bool。
    var kind: Kind { looksLikePC ? .computer : .server }

    /// 拿去问电脑用。
    var pcAddress: PCAgent.Address { PCAgent.Address(host: pcHost, port: pcPort, code: "") }

    var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把用户写的多行文本解析成请求头。
    /// 写得不对的行直接忽略，不因为一行填错就整个连不上。
    var headers: [String: String] {
        var out: [String: String] = [:]
        for line in headerLines.split(whereSeparator: { $0.isNewline }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { out[key] = value }
        }
        return out
    }

    /// 地址看着像不像话 —— 界面上先粗筛一下，省得用户对着一个空地址等超时。
    var looksValid: Bool {
        let text = trimmedURL.lowercased()
        return (text.hasPrefix("http://") || text.hasPrefix("https://"))
            && URL(string: trimmedURL)?.host != nil
    }
}

// ⚠️ 这个 `init(from:)` 是**故意的**，不是啰嗦。
//
// 用编译器自动合成的那个解码器时，**任何**一个字段在老数据里缺失，整个数组就解不出来；
// 而 `MCPStore.load()` 写的是 `try?` —— 解失败就直接 return，
// 结果是**用户已经配好的服务器全部静默消失**，界面上看着就像「从来没加过」。
// 每加一个新字段都会再踩一次（`pcHost`/`pcPort` 就是这么加进来的）。
//
// 放在 extension 里是为了保留逐成员初始化器 `MCPServerConfig(name:url:headerLines:)`。
extension MCPServerConfig {

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)

        // 缺字段 → 默认值；字段类型不对（手改过 JSON）→ 也走默认值，不抛。
        // 一条配置坏了不该连累另外几条。
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            let decoded = (try? box.decodeIfPresent(T.self, forKey: key)) ?? nil
            return decoded ?? fallback
        }

        id = value(.id, UUID().uuidString)
        name = value(.name, "MCP 服务器")
        url = value(.url, "")
        headerLines = value(.headerLines, "")
        enabled = value(.enabled, true)
        pcHost = value(.pcHost, "")
        pcPort = value(.pcPort, 0)
    }
}

/// 服务器上的一个工具（只有连上时才拿得到，所以不落盘）。
struct MCPToolInfo {
    var name: String
    var description: String
    /// 给模型看的 JSON Schema。是任意结构的 JSON，不适合序列化。
    var parameters: [String: Any]
    var serverID: String
    var serverName: String
}

enum MCPError: LocalizedError {
    case badURL
    case badResponse
    case http(code: Int, body: String)
    case remote(message: String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "地址不对 —— 要完整的 http 或 https 地址。"
        case .badResponse:
            return "服务器返回的不是 MCP 格式（可能这个地址不是 MCP 服务）。"
        case .http(let code, let body):
            let hint = body.isEmpty ? "" : "：\(body.prefix(120))"
            return "服务器返回 HTTP \(code)\(hint)"
        case .remote(let message):
            return "服务器报错：\(message)"
        }
    }
}

/// 和一个 MCP 服务器的连接。
///
/// 走的是 MCP 的 **Streamable HTTP** —— iOS 上没法起子进程，
/// 所以只能连 HTTP 服务，那种「本地 stdio」的方式用不了。
/// 这也是为什么配置里要填一个地址：服务器得跑在别处（你的电脑、服务器、内网）。
final class MCPClient {

    let config: MCPServerConfig

    /// 服务器在 initialize 时给的会话号，之后的请求都要带上。
    private var sessionID: String?
    private var nextID = 1

    init(config: MCPServerConfig) {
        self.config = config
    }

    // MARK: - 握手

    /// 打招呼并换取工具列表。返回服务器自报的名字，连不上就抛。
    @discardableResult
    func initialize() async throws -> String {
        let result = try await rpc(
            "initialize",
            params: [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "Aevis", "version": "1.0"]
            ],
            id: takeID()
        )

        // 规范要求握手完再发一个通知。服务器不回东西，失败也不影响后面。
        // `_ =` 明确表示**故意丢掉返回值** —— 不然编译器会警告"结果没被用到"。
        _ = try? await rpc("notifications/initialized", params: [:], id: nil)

        let info = result["serverInfo"] as? [String: Any]
        let title = (info?["name"] as? String) ?? config.name
        let version = (info?["version"] as? String) ?? ""
        return version.isEmpty ? title : "\(title) \(version)"
    }

    // MARK: - 工具

    func listTools() async throws -> [MCPToolInfo] {
        let result = try await rpc("tools/list", params: [:], id: takeID())
        let raw = (result["tools"] as? [[String: Any]]) ?? []

        return raw.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let schema = (item["inputSchema"] as? [String: Any]) ?? [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ]
            return MCPToolInfo(
                name: name,
                description: (item["description"] as? String) ?? "",
                parameters: schema,
                serverID: config.id,
                serverName: config.name
            )
        }
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await rpc(
            "tools/call",
            params: ["name": name, "arguments": arguments],
            id: takeID()
        )
        let text = Self.text(from: result["content"])
        if (result["isError"] as? Bool) == true {
            return text.isEmpty ? "（这个工具报错了，但没说原因）" : "（工具报错）\(text)"
        }
        return text.isEmpty ? "（这个工具没有返回内容）" : text
    }

    /// MCP 的返回是一组内容块，这里只取文字。
    /// 图片、音频那些先跳过 —— ta要的是能读懂的信息。
    static func text(from content: Any?) -> String {
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard let type = block["type"] as? String else { return nil }
            if type == "text" { return block["text"] as? String }
            if type == "resource", let resource = block["resource"] as? [String: Any] {
                return resource["text"] as? String
            }
            return nil
        }
        .joined(separator: "\n")
    }

    // MARK: - 底层

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    /// 发一条 JSON-RPC。`id` 给 nil 表示这是通知，不等结果。
    private func rpc(_ method: String, params: [String: Any]?, id: Int?) async throws -> [String: Any] {
        guard config.looksValid, let url = URL(string: config.trimmedURL) else {
            throw MCPError.badURL
        }

        var payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { payload["params"] = params }
        if let id { payload["id"] = id }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 两个都收 —— 有的实现直接回 JSON，有的回 SSE 流
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse }

        // 服务器可能在这时候才给会话号
        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
            sessionID = issued
        }

        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        if id == nil { return [:] }  // 通知不需要回复
        return try Self.parse(data, contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }

    /// 响应体可能是纯 JSON，也可能是 SSE（一行行 `data: {...}`）。
    /// 两种都得认 —— 不同实现给的不一样，只认一种会连不上大半的服务器。
    static func parse(_ data: Data, contentType: String?) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? ""
        let looksLikeSSE = (contentType ?? "").contains("text/event-stream")
            || text.hasPrefix("event:")
            || text.contains("\ndata:")

        if looksLikeSSE {
            for line in text.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }
                let body = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)),
                      let json = object as? [String: Any] else { continue }

                if let error = json["error"] as? [String: Any] {
                    throw MCPError.remote(message: (error["message"] as? String) ?? "未说明")
                }
                if let result = json["result"] as? [String: Any] { return result }
            }
            throw MCPError.badResponse
        }

        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw MCPError.badResponse
        }
        if let error = json["error"] as? [String: Any] {
            throw MCPError.remote(message: (error["message"] as? String) ?? "未说明")
        }
        guard let result = json["result"] as? [String: Any] else {
            throw MCPError.badResponse
        }
        return result
    }
}
