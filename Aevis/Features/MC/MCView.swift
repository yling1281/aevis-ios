import SwiftUI

/// 一个可以一起玩的「ta」。
///
/// ⚠️ 现在用的是**本地假数据** —— 数据源抽在 `MCPersonaSource` 后面，
///    以后换成真的接口只改那一处的实现，这一页一行都不用动。
struct MCPersona: Identifiable, Hashable {
    var id: String
    var name: String
    /// 一句话说ta是哪种玩家。
    var tagline: String
}

/// 「有哪些人设可以选」这件事的来源。
///
/// ⚠️ 抽成协议是有意的（跟电脑版一个做法）：现在是本地写死的几条，
///    等服务器那边给了真名单，新写一个实现替换掉就行。
protocol MCPersonaSource {
    func personas() -> [MCPersona]
}

/// 先用这一份本地名单。
struct LocalMCPersonaSource: MCPersonaSource {
    func personas() -> [MCPersona] {
        [
            MCPersona(id: "mika", name: "未影", tagline: "红石工程师，喜欢把小镇盖得整整齐齐"),
            MCPersona(id: "kuri", name: "栗子", tagline: "探洞一哥，看见钻石就走不动路"),
            MCPersona(id: "sora", name: "空", tagline: "爱种地爱养鸡，慢悠悠过日子的那种"),
            MCPersona(id: "nagi", name: "凪", tagline: "话不多，但你掉岩浆里他一定跳下去捞你")
        ]
    }
}

/// 那台「我的世界」服务器的桥。
///
/// ⚠️ **别自己写 HTTP 客户端** —— 走的是项目里已有的 `MCPServerConfig` +
///    `MCPClient`（它们已经处理了 Streamable HTTP、SSE、会话号这些）。
///    这里的 header 就是配置里那个「一行一个『键: 值』」的写法。
enum MCBridge {
    static let serverName = "我的世界"
    static let serverURL = "http://106.52.113.18:9192/mcp"
    static let headerLine = "X-Token: aevis-mc-2026"

    static var config: MCPServerConfig {
        MCPServerConfig(name: serverName, url: serverURL, headerLines: headerLine)
    }

    /// 选中的那个人设存这儿（落盘，下次进来还在）。
    static let selectedKey = "aevis.mc.selectedPersona"
}

/// 「一起玩」—— 选个人设，看ta陪你在《我的世界》里干什么。
///
/// 用户 2026-10-04：看完电脑版之后要「手机端也同步这些」。
struct MCView: View {

    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var mcp = MCPStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    private let source: MCPersonaSource = LocalMCPersonaSource()

    @State private var selectedID: String = ""
    @State private var status: String?
    @State private var tools: [MCPToolInfo] = []
    @State private var busy = false
    @State private var shePlaying = false

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    private var personas: [MCPersona] { source.personas() }

    private var selected: MCPersona? {
        personas.first { $0.id == selectedID } ?? personas.first
    }

    init() {
        _selectedID = State(initialValue: UserDefaults.standard.string(forKey: MCBridge.selectedKey) ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    personaList
                    connectCard
                    liveCard
                    footNote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("一起玩")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .aevisScreen("一起玩")
    }

    // MARK: - 顶部

    private var hero: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                AevisAvatar(source: .ai, size: 52, seed: personaStore.persona.avatarSeed)
                Image(systemName: "gamecontroller.fill")
                    .font(.aevis(16))
                    .foregroundStyle(accent.opacity(0.9))
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Image(systemName: "cube.fill")
                        .font(.aevis(20))
                        .foregroundStyle(accent)
                }
                .frame(width: 52, height: 52)
            }

            Text("\(taName)陪你玩《我的世界》")
                .font(.aevis(15, weight: .medium))
                .foregroundStyle(.primary)

            Text(statusLine)
                .font(.aevis(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .aevisGlass(cornerRadius: 22)
    }

    private var statusLine: String {
        shePlaying ? "\(Pronoun.current)正在游戏里等你。" : "选一种玩法，进游戏就是\(Pronoun.current)陪着你。"
    }

    // MARK: - 选人设

    private var personaList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("选一种玩法")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("点一下就行")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            ForEach(personas) { item in
                personaRow(item)
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func personaRow(_ item: MCPersona) -> some View {
        let isOn = selected?.id == item.id
        return Button {
            selectedID = item.id
            UserDefaults.standard.set(item.id, forKey: MCBridge.selectedKey)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.fill")
                    .font(.aevis(14))
                    .foregroundStyle(isOn ? accent : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.06)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(item.tagline)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.aevis(17))
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 连服务器

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("连上\(Pronoun.current)的服务器")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("服务器：\(MCBridge.serverURL)")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            if let status {
                Text(status)
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    connect(probe: false)
                } label: {
                    Text(busy ? "连接中…" : "连一下")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(accent.opacity(busy ? 0.5 : 1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Button {
                    connect(probe: true)
                } label: {
                    Text("看\(Pronoun.current)忙不忙")
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .aevisGlass(cornerRadius: 13)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            if !tools.isEmpty {
                Text("拿到 \(tools.count) 个工具。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            }

            Button {
                adoptIntoHands()
            } label: {
                Text(alreadyAdopted ? "已经加进「MCP 外接工具」了" : "把这台服务器加进\(Pronoun.current)的外接工具")
                    .font(.aevis(12.5))
                    .foregroundStyle(alreadyAdopted ? Color.secondary : accent)
            }
            .buttonStyle(.plain)
            .disabled(alreadyAdopted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var alreadyAdopted: Bool {
        mcp.servers.contains { $0.url.trimmingCharacters(in: .whitespacesAndNewlines) == MCBridge.serverURL }
    }

    // MARK: - 上灵动岛

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("让灵动岛知道\(Pronoun.current)在玩")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(Pronoun.current)进游戏的时候，灵动岛上会亮一句「正在玩《我的世界》」；退出来就收掉。")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shePlaying {
                Button {
                    stopPlaying()
                } label: {
                    Text("退出游戏")
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(accent)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    startPlaying()
                } label: {
                    Text("进游戏")
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(accent)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var footNote: some View {
        Text("玩法名单现在用的是一份示例数据；换成真名单只改一个数据源，这一页不用动。")
            .font(.aevis(11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 动作

    /// 连一次服务器。`probe` 为真时顺带问一句「ta现在在不在玩」。
    private func connect(probe: Bool) {
        guard !busy else { return }
        busy = true
        status = "正在连接…"
        Task { @MainActor in
            let client = MCPClient(config: MCBridge.config)
            do {
                let who = try await client.initialize()
                let list = try await client.listTools()
                tools = list
                if probe {
                    await askHerPresence(client: client, tools: list, who: who)
                } else {
                    status = list.isEmpty
                        ? "连上「\(who)」了，但它没给出工具。"
                        : "连上「\(who)」了，拿到 \(list.count) 个工具。"
                }
            } catch {
                tools = []
                status = error.localizedDescription
            }
            busy = false
        }
    }

    /// 找一台服务器里那个「谁在线 / 在干什么」的工具。找不到就返回 nil。
    private func presenceTool(in list: [MCPToolInfo]) -> MCPToolInfo? {
        let hints = ["status", "online", "player", "who", "list", "state", "presence"]
        return list.first { tool in
            let name = tool.name.lowercased()
            return hints.contains { name.contains($0) }
        }
    }

    @MainActor
    private func askHerPresence(client: MCPClient,
                                tools list: [MCPToolInfo],
                                who: String) async {
        guard let probe = presenceTool(in: list) else {
            status = "连上「\(who)」了（\(list.count) 个工具），但没有「谁在玩」那样的工具。"
            return
        }
        let arguments = presenceArguments(for: probe)
        do {
            let text = try await client.callTool(name: probe.name, arguments: arguments)
            status = text
        } catch {
            status = error.localizedDescription
        }
    }

    /// 给那个工具凑一份参数：有 player / name 这种字段就带上当前人设名字，没有就空着。
    private func presenceArguments(for tool: MCPToolInfo) -> [String: Any] {
        guard let properties = tool.parameters["properties"] as? [String: Any] else { return [:] }
        let player = selected?.name ?? taName
        for key in ["player", "playerName", "name", "username", "user"] where properties[key] != nil {
            return [key: player]
        }
        return [:]
    }

    private func adoptIntoHands() {
        guard !alreadyAdopted else { return }
        _ = mcp.add(name: MCBridge.serverName,
                    url: MCBridge.serverURL,
                    headerLines: MCBridge.headerLine)
        status = "加好了 —— \(Pronoun.current)的工具清单里就多了这台服务器。"
    }

    private func startPlaying() {
        shePlaying = true
        let name = personaStore.persona.name
        Task { @MainActor in
            LiveIslandCenter.shared.push(name: name, text: "正在玩《我的世界》")
        }
    }

    private func stopPlaying() {
        shePlaying = false
        Task { @MainActor in
            LiveIslandCenter.shared.end()
        }
    }
}
