import Foundation
import SwiftUI

/// MCP 服务器的管理，以及「把远程工具变成她的手」这件事。
///
/// ## 为什么只要挂在 `DeviceTools.all()` 上就够了
///
/// 她所有会用到工具的地方 —— 打字聊天、**语音通话**、一起听、主动消息、朋友圈 ——
/// 走的都是同一个 `DeviceTools.all()`。所以外接的工具**接一次，处处可用**，
/// 包括你直接跟她说话的时候。
///
/// ## 为什么必须填一个地址
///
/// MCP 有两种跑法：本地子进程（stdio）和远程 HTTP。
/// **iOS 不让 App 起子进程**，所以只能用 HTTP —— 服务器得跑在别处
/// （你的电脑、家里的软路由、一台服务器都行），Aevis 连过去。
final class MCPStore: ObservableObject {

    static let shared = MCPStore()

    @Published private(set) var servers: [MCPServerConfig] = []
    /// 已经拉到的工具（只在内存里 —— 里面是任意 JSON Schema，不适合落盘）
    @Published private(set) var tools: [MCPToolInfo] = []
    /// 每个服务器最近一次的连接结果，界面上直接显示
    @Published private(set) var status: [String: String] = [:]
    /// 正在连接的服务器 id
    @Published private(set) var busy: Set<String> = []

    private var clients: [String: MCPClient] = [:]

    private static let key = "aevis.mcpServers"

    private init() {
        load()
        // 启动就把已启用的连上 —— 否则要等用户专门去设置页点一次才生效
        Task { await connectEnabled() }
    }

    // MARK: - 增删改

    @discardableResult
    func add(name: String, url: String, headerLines: String) -> MCPServerConfig {
        let server = MCPServerConfig(name: name, url: url, headerLines: headerLines)
        servers.append(server)
        persist()
        return server
    }

    func update(_ server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index] = server
        persist()
        // 配置变了旧连接就不作数了，重新连一次
        clients[server.id] = nil
        tools.removeAll { $0.serverID == server.id }
        status[server.id] = server.enabled ? "配置改过了，正在重连…" : "已关闭。"
        if server.enabled {
            Task { await connect(server) }
        }
    }

    func remove(_ server: MCPServerConfig) {
        servers.removeAll { $0.id == server.id }
        clients[server.id] = nil
        tools.removeAll { $0.serverID == server.id }
        status[server.id] = nil
        persist()
    }

    func setEnabled(_ enabled: Bool, for server: MCPServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[index].enabled = enabled
        persist()
        if enabled {
            Task { await connect(servers[index]) }
        } else {
            clients[server.id] = nil
            tools.removeAll { $0.serverID == server.id }
            status[server.id] = "已关闭 —— 它的工具她暂时用不了。"
        }
    }

    /// 某个服务器贡献了几个工具（列表上显示）。
    func toolCount(for id: String) -> Int {
        tools.filter { $0.serverID == id }.count
    }

    // MARK: - 连接

    @MainActor
    @discardableResult
    func connect(_ server: MCPServerConfig) async -> String {
        guard server.looksValid else {
            let line = "地址要先填对（要 http:// 或 https:// 开头）。"
            status[server.id] = line
            return line
        }

        busy.insert(server.id)
        status[server.id] = "正在连接…"
        defer { busy.remove(server.id) }

        let client = MCPClient(config: server)
        do {
            let who = try await client.initialize()
            let list = try await client.listTools()

            clients[server.id] = client
            tools.removeAll { $0.serverID == server.id }
            tools.append(contentsOf: list)

            let line = list.isEmpty
                ? "连上「\(who)」了，但它没有提供工具。"
                : "连上「\(who)」了，拿到 \(list.count) 个工具。"
            status[server.id] = line
            return line
        } catch {
            clients[server.id] = nil
            tools.removeAll { $0.serverID == server.id }
            let line = error.localizedDescription
            status[server.id] = line
            return line
        }
    }

    @MainActor
    func connectEnabled() async {
        for server in servers where server.enabled {
            _ = await connect(server)
        }
    }

    @MainActor
    func reconnectAll() async {
        await connectEnabled()
    }

    // MARK: - 变成她的手
    //
    // 下面这个属性**不能标 @MainActor** —— 因为 `DeviceTools.all()` 是同步的、
    // 而且会在后台线程被调用。工具早就在前面拉好放在 `tools` 里了，这里只是读一下。

    /// 已经连上的服务器提供的工具，转成她能调用的一只手。
    var bridgedTools: [DeviceTool] {
        guard !tools.isEmpty else { return [] }

        var used = Set(DeviceTools.builtinTools.map(\.name))
        var out: [DeviceTool] = []

        for info in tools {
            guard let client = clients[info.serverID] else { continue }

            var name = info.name
            if used.contains(name) {
                // 和别的工具重名了（比如都叫 read_file）——
                // 加一层服务器前缀，让模型分得清是哪边的
                name = "mcp_\(Self.slug(info.serverName))_\(info.name)"
            }
            guard !used.contains(name), !name.isEmpty else { continue }
            used.insert(name)

            let schema = info.parameters.isEmpty
                ? [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ]
                : info.parameters

            let origin = info.serverName
            let remote = info.name
            let summary = info.description.isEmpty
                ? "来自 MCP 服务器「\(origin)」的工具。"
                : "\(info.description)\n（来自 MCP 服务器「\(origin)」）"

            out.append(
                DeviceTool(
                    name: name,
                    title: "动了 \(origin) 的「\(remote)」",
                    description: summary,
                    parameters: schema
                ) { arguments in
                    do {
                        return try await client.callTool(name: remote, arguments: arguments)
                    } catch {
                        return "调用失败：\(error.localizedDescription)"
                    }
                }
            )
        }
        return out
    }

    /// 服务器名字里可能有中文和空格，塞进工具名里不合适，转成下划线连接的样子。
    private static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let raw = String(mapped)
        // 连续下划线压成一个，两头去掉
        var out = ""
        var lastWasUnderscore = false
        for character in raw {
            if character == "_" {
                if !lastWasUnderscore { out.append(character) }
                lastWasUnderscore = true
            } else {
                out.append(character)
                lastWasUnderscore = false
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "server" : String(trimmed.prefix(16))
    }

    // MARK: - 存

    private func load() {
        guard let text = Keychain.get(Self.key),
              let data = text.data(using: .utf8),
              let saved = try? JSONDecoder().decode([MCPServerConfig].self, from: data) else {
            return
        }
        servers = saved
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers),
              let text = String(data: data, encoding: .utf8) else { return }
        // 存钥匙串：地址和认证头都算凭据，放 UserDefaults 里不合适
        _ = Keychain.set(text, for: Self.key)
    }
}
