import SwiftUI

/// 「外接能力」设置卡片 —— 给ta接上一台电脑（和那台电脑上连着的手机）。
///
/// ## 为什么入口是「填一个 6 位码」而不是「填一个 URL」
///
/// 电脑上跑着「Aevis 电脑助手」那个窗口时，屏幕上会写着一个 6 位配对码和
/// 一个局域网地址。用户真正要做的只有一件事：**把那两样东西填进来**。
/// 至于「拿码换令牌 → 拼出 /mcp 地址 → 把令牌写成请求头」这一串，
/// 全在 `PCAgent` 里做完 —— 让用户自己去拼 URL 和 Bearer 头是不合理的，
/// 而且电脑那边**必须**带令牌才让连（不然同一个 WiFi 下谁都能操控那台电脑）。
///
/// 手动填地址那种方式还留着（最下面的「手动添加 MCP 服务器」），
/// 给连别家 MCP 服务用。
struct MCPCard: View {

    @ObservedObject private var store = MCPStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// ⚠️ 一个视图上只能挂**一个** `.sheet` —— 后面那个会顶掉前面那个。
    ///    所以「添加电脑」和「改一条」共用一个 sheet，靠这个枚举分。
    private enum SheetTarget: Identifiable {
        case addComputer
        case edit(MCPServerConfig)

        var id: String {
            switch self {
            case .addComputer: return "add-computer"
            case .edit(let server): return "edit-\(server.id)"
            }
        }
    }

    @State private var sheet: SheetTarget?
    @State private var scanMode: ScanMode?
    @State private var expanded: Set<String> = []

    // 添加电脑的草稿
    @State private var draftName = ""
    @State private var draftAddress = ""
    @State private var draftCode = ""
    @State private var addBusy = false
    @State private var addError = ""
    @State private var addStep = ""

    /// 「查找附近的设备」扫到的结果（局域网里跑着 Aevis 电脑助手的机器）。
    ///
    /// 用户 2026-10-01 要的：「查找附近的设备，这里可以找到它，然后直接连接」。
    /// 扫到一条你点一下，地址就填好了 —— 不用手打 IP。
    @State private var found: [PCAgent.Machine] = []
    @State private var scanning = false
    @State private var scanNote = ""

    // 手动添加的草稿
    @State private var draftURL = ""
    @State private var draftHeaders = ""

    /// 每台电脑的手机状态。key 是服务器 id。
    @State private var phones: [String: PhonePanel] = [:]

    private enum ScanMode: Identifiable {
        case addComputer
        var id: String { "scan" }
    }

    /// 一台电脑的「手机」那一段的全部状态。
    private struct PhonePanel {
        var status: PCAgent.PhoneStatus?
        var error = ""
        var code = ""
        var message = ""
        var messageOK = false
        var busy = false
        var loaded = false
        /// 已经连着的时候默认不显示输入框（那一行挤在那儿没用）。
        /// 用户点了「换一台手机」再把它打开。
        var wantRepair = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("外接能力（电脑 / 手机）")

            // ⚠️ 这一段要**把两件事分开说**：连电脑、连安卓手机。
            //    以前只写"多了一台电脑……也能操控那台电脑上连着的安卓手机"，
            //    用户 2026-10-01 读到的就是"我要的是手机对手机，你怎么老让我连电脑"——
            //    他以为**电脑**是最终目标，其实电脑只是那个会说安卓协议的角色
            //    （iPhone 上没有 adb，这一步绕不过去，见 `PCAgent.scanLocalNetwork`
            //      上面那段注释）。所以这里明写"为了连手机"，别让他以为走错了。
            Text("想让\(Pronoun.current)操控安卓手机：让安卓手机和这台 iPhone 连同一个 WiFi，"
                 + "然后按下面「添加电脑」的步骤走一遍 —— "
                 + "连上之后，那台安卓手机就会出现在这台电脑下面，配对一次就行。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Text("想让\(Pronoun.current)操控电脑：电脑上双击「Aevis 电脑助手」，"
                 + "屏幕上会出现一个二维码和一个 6 位配对码 —— 扫一下就行。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            rule

            if store.servers.isEmpty {
                Text("还没加过。先在电脑上双击「Aevis 电脑助手」，"
                     + "再点下面的「添加电脑」。")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                ForEach(store.servers) { server in
                    serverRow(server)
                    rule
                }
            }

            addRow
            manualRow
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(item: $sheet) { target in
            switch target {
            case .addComputer:
                addComputerSheet
            case .edit(let server):
                manualSheet(server)
            }
        }
        .fullScreenCover(item: $scanMode) { _ in
            scanner
        }
        .task {
            // 进来就把电脑上的手机状态问一遍（不然用户得先点一次「刷新」）
            for server in store.servers where server.looksLikePC {
                await loadPhone(server, quiet: true)
            }
        }
    }

    // MARK: - 一行电脑

    private func serverRow(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: server.kind == .computer ? "desktopcomputer" : "server.rack")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(settings.accentColor.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Text(server.trimmedURL)
                        .font(.aevisMono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                if store.busy.contains(server.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(
                        get: { server.enabled },
                        set: { store.setEnabled($0, for: server) }
                    ))
                    .labelsHidden()
                }
            }

            // 两个「常显」的小标签：① 这台是什么设备；② 它给了几个工具。
            //
            // 为什么要常显（都是用户 2026-10-02 要的）：
            //   ① 「不是所有设备都是电脑」—— 类型得一眼看出来，别让手动加的米家
            //      那种 MCP 也显示成一台电脑；所以这里把「电脑 / 服务器」直接写出来。
            //   ② 「能显示这个 MCP 有多少工具吗」—— 以前只有连上、且工具数 > 0 时
            //      才展开下面那个列表，「还有 N 个」又得 N > 3 才出现，所以数量平时
            //      根本看不到。现在单独一行计数，**和下面的 `toolList` 并存**，不替代它。
            HStack(spacing: 6) {
                pill(deviceKindLabel(server), tint: deviceKindTint(server))
                pill(toolCountText(for: server), tint: toolCountTint(for: server))
                Spacer(minLength: 0)
            }

            if let line = store.status[server.id] {
                Text(line)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if server.enabled, toolTotal(for: server.id) > 0 {
                toolList(for: server)
            }

            if server.looksLikePC, server.enabled {
                phoneSection(server)
            }

            HStack(spacing: 16) {
                Button("重连") {
                    Task { await store.connect(server) }
                }
                .font(.aevis(13))
                .foregroundStyle(settings.accentColor)

                Button("改") {
                    draftName = server.name
                    draftAddress = server.pcHost.isEmpty
                        ? server.url
                        : "\(server.pcHost):\(server.pcPort)"
                    draftCode = ""
                    draftURL = server.url
                    draftHeaders = server.headerLines
                    addError = ""
                    addStep = ""
                    sheet = .edit(server)
                }
                .font(.aevis(13))
                .foregroundStyle(.secondary)

                // ⚠️ 内置的那条（米家）**不给「删掉」** —— 删了下一次启动
                //    `ensureBuiltins()` 又把它补回来，用户会觉得像流氓软件。
                //    不想用就把左边那个开关关掉，那样它还在列表里、只是不连。
                if !store.isBuiltin(server) {
                    Button("删掉") {
                        phones[server.id] = nil
                        store.remove(server)
                    }
                    .font(.aevis(13))
                    .foregroundStyle(.red)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 手机那一段

    @ViewBuilder
    private func phoneSection(_ server: MCPServerConfig) -> some View {
        let panel = phones[server.id] ?? PhonePanel()

        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "iphone.gen3")
                    .font(.aevis(12, weight: .medium))
                    .foregroundStyle(settings.accentColor)
                Text("电脑上连着的手机")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 6)

                if panel.busy || (!panel.loaded && panel.status == nil) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("刷新") {
                        Task { await loadPhone(server, quiet: false) }
                    }
                    .font(.aevis(11.5))
                    .foregroundStyle(settings.accentColor)
                }
            }

            if !panel.error.isEmpty {
                Text(panel.error)
                    .font(.aevis(11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let status = panel.status {
                phoneBody(server, status: status, panel: panel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    @ViewBuilder
    private func phoneBody(_ server: MCPServerConfig,
                           status: PCAgent.PhoneStatus,
                           panel: PhonePanel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(status.connected ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
            Text(status.summary)
                .font(.aevis(11.5))
                .foregroundStyle(status.connected ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        if !status.adbOK {
            Text("电脑上 adb 有点问题：\(status.adbError)")
                .font(.aevis(11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        if let pairing = status.pairing.first {
            Text("扫到配对端口 \(pairing.text) —— 手机上那个弹窗别关。")
                .font(.aevis(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if !status.hint.isEmpty {
            Text(status.hint)
                .font(.aevis(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        // 已经连着的时候，配对码那一行就没必要挤在那儿了 —— 想换手机再点开
        if status.connected, !panel.wantRepair {
            Button("换一台手机") {
                var next = phones[server.id] ?? PhonePanel()
                next.wantRepair = true
                next.message = "在手机上开「使用配对码配对设备」，把码填进来。"
                next.messageOK = false
                phones[server.id] = next
            }
            .font(.aevis(11.5))
            .foregroundStyle(settings.accentColor)
        } else {
            pairRow(server, panel: panel)

            // ——— 手机上要做的那两步 ———
            //
            // ⚠️ 这段**必须写出来**：用户 2026-10-01 要的「苹果对安卓直接连」，
            //    卡住他的从来不是 App 这边，而是**他不知道安卓那边要开什么**。
            //    光给一个"6 位配对码"输入框，他只会问"码在哪"。
            //    顺序也不能反：先开弹窗 → 再扫（弹窗一关，mDNS 里就只剩连接端口了）。
            VStack(alignment: .leading, spacing: 5) {
                Text("手机上要做的两步")
                    .font(.aevis(11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("① 安卓手机：设置 → 开发者选项 → 无线调试 → 打开开关，"
                     + "然后点「使用配对码配对设备」。那个弹窗先别关。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("② 弹窗里会写一个 6 位码和一个 192.168 开头的地址 —— "
                     + "码填在上面那个框里，地址不用管，电脑会自己找到它。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("配一次就够了，以后手机开着无线调试就能直接连。"
                     + "手机重启之后无线调试会自动关，回去把开关打开就行。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }

        if !panel.message.isEmpty {
            Text(panel.message)
                .font(.aevis(11.5))
                .foregroundStyle(panel.messageOK ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func pairRow(_ server: MCPServerConfig, panel: PhonePanel) -> some View {
        HStack(spacing: 9) {
            TextField("手机的 6 位配对码", text: Binding(
                get: { phones[server.id]?.code ?? "" },
                set: { newValue in
                    var next = phones[server.id] ?? PhonePanel()
                    next.code = String(newValue.filter(\.isNumber).prefix(6))
                    phones[server.id] = next
                }
            ))
            .font(.aevisMono(14))
            .keyboardType(.numberPad)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Button {
                Task { await pairPhone(server) }
            } label: {
                Text("配对")
                    .font(.aevis(13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(digitsOf(panel.code).count == 6
                                  ? settings.accentColor
                                  : Color.secondary.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(digitsOf(panel.code).count != 6 || panel.busy)
        }
    }

    // MARK: - 设备类型 / 工具数量（行上常显的两个标签）

    /// 设备类型的文字：「电脑」还是「服务器」。
    private func deviceKindLabel(_ server: MCPServerConfig) -> String {
        switch server.kind {
        case .computer: return "电脑"
        case .server: return "服务器"
        }
    }

    /// 设备类型的颜色：电脑用强调色（它是更特别的那一种），普通服务器用辅助色。
    private func deviceKindTint(_ server: MCPServerConfig) -> Color {
        switch server.kind {
        case .computer: return settings.accentColor
        case .server: return Color.secondary
        }
    }

    /// 「N 个工具」这句话 —— 始终显示，并且按**连接状态**说话。
    ///
    /// 为什么不是简单地写「0 个工具」：`tools` 为空有几种完全不同的原因，
    /// 对用户是几回事 ——
    ///   · 正在连             →「正在数…」（别让他以为真的只有 0 个）
    ///   · 连上了、那边没工具  →「没有工具」
    ///   · 没连上             →「没连上」（是"没连上"，不是"没有工具"）
    ///   · 用户手动关了        →「已关闭」
    private func toolCountText(for server: MCPServerConfig) -> String {
        if store.busy.contains(server.id) { return "正在数…" }
        let total = toolTotal(for: server.id)
        if total > 0 { return "\(total) 个工具" }
        if !server.enabled { return "已关闭" }
        if store.isConnected(server.id) { return "没有工具" }
        return "没连上"
    }

    /// 计数标签的颜色：真拿到工具才算"好用"，给个好看的颜色；其余情况一律辅助色。
    private func toolCountTint(for server: MCPServerConfig) -> Color {
        toolTotal(for: server.id) > 0 ? settings.accentColor : Color.secondary
    }

    /// 一个共用的小圆角标签 —— 设备类型和工具数量两处共用，免得各写一份样式跑偏。
    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.aevis(10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
    }

    // MARK: - 工具列表

    private func toolTotal(for id: String) -> Int {
        store.tools.filter { $0.serverID == id }.count
    }

    private func visibleTools(for id: String) -> [MCPToolInfo] {
        let mine = store.tools.filter { $0.serverID == id }
        return expanded.contains(id) ? mine : Array(mine.prefix(3))
    }

    private func toolList(for server: MCPServerConfig) -> some View {
        let total = toolTotal(for: server.id)

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(visibleTools(for: server.id), id: \.name) { tool in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(tool.name)
                        .font(.aevisMono(11.5))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(tool.description.isEmpty
                         ? "（那边没写说明）"
                         : String(tool.description.prefix(38)))
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }

            if total > 3 {
                Button {
                    if expanded.contains(server.id) {
                        expanded.remove(server.id)
                    } else {
                        expanded.insert(server.id)
                    }
                } label: {
                    Text(expanded.contains(server.id) ? "收起来" : "还有 \(total - 3) 个")
                        .font(.aevis(11.5))
                        .foregroundStyle(settings.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - 入口

    private var addRow: some View {
        Button {
            draftName = ""
            draftAddress = ""
            draftCode = ""
            addError = ""
            addStep = ""
            sheet = .addComputer
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.aevis(14, weight: .medium))
                Text("添加电脑")
                    .font(.aevis(14, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(settings.accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var manualRow: some View {
        Button {
            draftName = ""
            draftURL = ""
            draftHeaders = ""
            sheet = .edit(MCPServerConfig(name: "", url: "", headerLines: ""))
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .font(.aevis(12.5))
                Text("手动添加 MCP 服务器")
                    .font(.aevis(12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 添加电脑

    /// 「查找附近的设备」那一段。
    ///
    /// 干什么：在局域网里挨个探一遍常见网段，认得出「Aevis 电脑助手」的列出来。
    /// 点一条 → 地址自动填好 → 你只管填配对码。
    @ViewBuilder
    private var foundComputers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("查找附近的设备")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if scanning {
                    ProgressView().controlSize(.small)
                    Text("正在找…")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Button(found.isEmpty ? "开始查找" : "重新找") {
                        Task { await scanNearby() }
                    }
                    .font(.aevis(12.5))
                    .foregroundStyle(settings.accentColor)
                }
            }

            if !found.isEmpty {
                ForEach(found, id: \.host) { machine in
                    Button {
                        draftAddress = "\(machine.host):\(machine.port)"
                        if draftName.isEmpty { draftName = machine.device }
                        addError = ""
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(settings.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(machine.device)
                                    .font(.aevis(13, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("\(machine.host):\(machine.port)")
                                    .font(.aevisMono(11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !scanNote.isEmpty {
                Text(scanNote)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// 在局域网里把跑着「Aevis 电脑助手」的机器找出来。
    ///
    /// ## 为什么不是 Bonjour
    /// 助手那个 EXE 是**普通 Windows 程序**，没注册 mDNS 服务 —— 扫 `_http._tcp`
    /// 又太脏（打印机、路由器、电视全在里头）。所以走**并发探测**：
    /// 本机 /24 网段 + 默认端口，200 多个地址一起发，1 秒多钟出结果。
    /// 认的标准是 `/pair.json` 里有 `device` 字段（见 `PCAgent.probe`）——
    /// 光"端口开着"不算，同一端口上可能是路由器后台。
    private func scanNearby() async {
        guard !scanning else { return }
        scanning = true
        found = []
        scanNote = ""

        let hits = await PCAgent.scanLocalNetwork()

        scanning = false
        found = hits
        if hits.isEmpty {
            scanNote = "没找到。检查一下：① 电脑上那个助手窗口开着吗；"
                + "② 手机和电脑在不在同一个 WiFi；"
                + "③ iPhone 设置 → 隐私与安全性 → 本地网络里的 Aevis 开着吗。"
        } else {
            scanNote = "点一条就把地址填好了，剩下的只要填配对码。"
        }
    }

    private var addComputerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("电脑上那个窗口里写着两样东西")
                            .font(.aevis(12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("把「局域网地址」和「配对码」照抄进来就行。"
                             + "也可以点下面的「扫码」，直接扫电脑屏幕上那个二维码 —— "
                             + "扫码最快，码和地址一起带进来，不用手打。")
                            .font(.aevis(11.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // ⭐ **扫码放最前面**（用户 2026-10-01：「查找附近的设备…直接连接」）。
                    //
                    // 为什么把它提到最上面：扫码是**唯一一步到位**的那条路 ——
                    // 电脑屏幕上那个二维码里装的是 `aevis://pc?host=…&port=…&code=…`，
                    // 扫完地址和配对码全填好了，连"确认"都不用点（见 `applyScanned`）。
                    // 手动填 IP 那条路要抄两样东西、还容易抄错，放后面当备胎。
                    if QRScannerView.isAvailable {
                        Button {
                            sheet = nil
                            scanMode = .addComputer
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 15, weight: .medium))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("扫一扫，直接连")
                                        .font(.aevis(14, weight: .medium))
                                    Text("对着电脑屏幕上那个二维码")
                                        .font(.aevis(11))
                                        .opacity(0.8)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(settings.accentColor)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    field("电脑地址", hint: "比如 192.168.1.10:\(PCAgent.defaultPort)",
                          text: $draftAddress, mono: true)

                    // 附近设备 —— 用户 2026-10-01：
                    // 「苹果的话，那边可以填入配对码和 IP，懂吗？就是查找附近的设备，
                    //   这里可以找到它，然后直接连接」。
                    //
                    // ⚠️ 这里扫的是**网里的 Aevis 电脑助手**，不是 iPhone 之间的
                    //    Bonjour 发现。iPhone 自己不会说安卓那套无线调试协议，
                    //    安卓也没有 iOS 的 Bonjour 服务可发 —— 两台手机**不可能**
                    //    互相发现。所以「附近」这一层能做的、也是唯一有意义的一件事，
                    //    就是把局域网里跑着助手的机器列出来给你点。
                    foundComputers

                    VStack(alignment: .leading, spacing: 6) {
                        Text("配对码")
                            .font(.aevis(12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("6 位数字", text: Binding(
                            get: { draftCode },
                            set: { draftCode = String($0.filter(\.isNumber).prefix(6)) }
                        ))
                        .font(.aevisMono(22))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                    }

                    field("给它起个名（可选）", hint: "不填就用电脑自己的名字",
                          text: $draftName)

                    // ⚠️ 扫码按钮搬到最上面去了（`sheet = nil` 之后就没它了，
                    //    重复放一个只会让用户犹豫点哪个）。

                    if !addError.isEmpty {
                        Text(addError)
                            .font(.aevis(12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if !addStep.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(addStep)
                                .font(.aevis(12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    Text("手机得和这台电脑在同一个 WiFi。整条链路只走局域网，"
                         + "不经过任何服务器 —— 配对码和令牌都出不了这个网。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
            .navigationTitle("添加电脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { sheet = nil }
                        .font(.aevis(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if addBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("连接") { Task { await submitComputer() } }
                            .font(.aevis(14, weight: .medium))
                            .disabled(!canSubmitComputer)
                    }
                }
            }
        }
    }

    private var canSubmitComputer: Bool {
        PCAgent.parse(draftAddress) != nil && digitsOf(draftCode).count == 6
    }

    private func submitComputer() async {
        guard let address = PCAgent.parse(draftAddress) else {
            addError = "地址看着不对。填电脑的 IP 就行，比如 192.168.1.10。"
            return
        }
        let code = digitsOf(draftCode)
        guard code.count == 6 else {
            addError = "配对码是 6 位数字。"
            return
        }

        addBusy = true
        addError = ""
        defer { addBusy = false }

        do {
            addStep = "在找这台电脑…"
            // 先用 /pair.json 认一下「这确实是 Aevis 电脑助手」。
            // 光「连得上」不够 —— 同一个端口上可能是路由器后台、别的服务，
            // 那种情况下来个明确的「这不是电脑助手」比后面一个 401 好查得多。
            let machine = try await PCAgent.probe(address)

            addStep = "在核对配对码…"
            let token = try await PCAgent.exchange(address, code: code)

            addStep = "在接上\(Pronoun.current)的工具…"
            let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            // ⚠️ 地址用**电脑报回来的那个**（machine.host/port），不是用户填的。
            //    用户可能填 127.0.0.1、也可能填主机名，电脑最清楚自己的局域网 IP。
            let server = PCAgent.serverConfig(
                name: name.isEmpty ? machine.device : name,
                machine: machine,
                token: token
            )
            store.addComputer(server)
            addStep = ""
            sheet = nil
        } catch {
            addStep = ""
            addError = error.localizedDescription
        }
    }

    // MARK: - 扫码

    private var scanner: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            QRScannerView { text in
                scanMode = nil
                applyScanned(text)
            }
            .ignoresSafeArea()

            VStack {
                Text("扫电脑屏幕上那个二维码")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.top, 26)
                Spacer()
                Button("取消") { scanMode = nil }
                    .font(.aevis(15))
                    .foregroundStyle(.white)
                    .padding(.bottom, 34)
            }
        }
    }

    /// 扫到的可能是 `aevis://pc?host=…&port=…&code=…`，也可能只是地址。
    private func applyScanned(_ text: String) {
        guard let address = PCAgent.parse(text) else { return }
        draftAddress = address.text
        if !address.code.isEmpty { draftCode = digitsOf(address.code) }
        addError = ""
        if !address.code.isEmpty {
            addStep = "扫到了，正在连…"
            Task { await submitComputer() }
        } else {
            sheet = .addComputer
        }
    }

    // MARK: - 手机：读状态 / 配对

    private func loadPhone(_ server: MCPServerConfig, quiet: Bool) async {
        guard server.looksLikePC else { return }

        var panel = phones[server.id] ?? PhonePanel()
        if !quiet { panel.busy = true }
        panel.error = ""
        if !quiet { panel.message = "" }
        phones[server.id] = panel

        do {
            let status = try await PCAgent.phoneStatus(server.pcAddress)
            var next = phones[server.id] ?? PhonePanel()
            next.status = status
            next.error = ""
            next.busy = false
            next.loaded = true
            // 已经连上了就不用再显示输入框了
            if status.connected, next.messageOK { next.code = "" }
            phones[server.id] = next
        } catch {
            var next = phones[server.id] ?? PhonePanel()
            next.error = error.localizedDescription
            next.busy = false
            next.loaded = true
            phones[server.id] = next
        }
    }

    private func pairPhone(_ server: MCPServerConfig) async {
        var panel = phones[server.id] ?? PhonePanel()
        let code = digitsOf(panel.code)
        guard code.count == 6 else { return }

        panel.busy = true
        panel.message = "在让电脑去配对…（手机上那个弹窗要开着）"
        panel.messageOK = false
        phones[server.id] = panel

        do {
            let outcome = try await PCAgent.pairPhone(server.pcAddress, code: code)
            var next = phones[server.id] ?? PhonePanel()
            next.busy = false
            next.message = outcome.message
            next.messageOK = outcome.ok
            if outcome.ok { next.code = "" }
            phones[server.id] = next
        } catch {
            var next = phones[server.id] ?? PhonePanel()
            next.busy = false
            next.message = error.localizedDescription
            next.messageOK = false
            phones[server.id] = next
        }

        await loadPhone(server, quiet: true)
    }

    // MARK: - 手动添加（老路子）

    private func manualSheet(_ server: MCPServerConfig) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("名字", hint: "自己认得就行，比如「我电脑」", text: $draftName)
                    field("地址", hint: "http://192.168.1.10:8000/mcp",
                          text: $draftURL, mono: true)
                    field("请求头（可选）", hint: "Authorization: Bearer xxxxx",
                          text: $draftHeaders, mono: true, lines: 3)

                    Text("地址要填 MCP 服务暴露的那个端点（通常是 /mcp 或 /sse）。"
                         + "需要认证的服务，把请求头按「名字: 值」的格式一行一个写进去。"
                         + "电脑助手的令牌就是这么填的 —— 只是「添加电脑」会自动做完。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(16)
            }
            .navigationTitle(server.name.isEmpty ? "添加 MCP 服务器" : server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { sheet = nil }
                        .font(.aevis(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { saveManual() }
                        .font(.aevis(14, weight: .medium))
                }
            }
        }
    }

    private func saveManual() {
        guard let target = sheet, case .edit(let server) = target else { return }
        sheet = nil

        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if store.servers.contains(where: { $0.id == server.id }) {
            var updated = server
            updated.name = name.isEmpty ? "MCP 服务器" : name
            updated.url = url
            updated.headerLines = draftHeaders
            // ⚠️ 只有「本来就是电脑」的那条才跟着改主机地址（比如用户换了电脑的 IP）。
            //    **手动添加的普通 MCP 绝不能被顺手变成电脑** —— 它的地址里也有一个 host，
            //    这里要是不加 `server.looksLikePC` 这个条件，手工服务器被"改"一次就会被填上
            //    pcHost / pcPort，界面上立刻变成 desktopcomputer 图标、还冒出「电脑上连着的
            //    手机」那一段（用户 2026-10-02 明确要求把"电脑"和"普通服务器"分清）。
            if server.looksLikePC, !draftAddress.isEmpty, let address = PCAgent.parse(draftAddress),
               "\(address.host):\(address.port)" != "\(server.pcHost):\(server.pcPort)" {
                updated.pcHost = address.host
                updated.pcPort = address.port
            }
            store.update(updated)
        } else {
            let added = store.add(
                name: name.isEmpty ? "MCP 服务器" : name,
                url: url,
                headerLines: draftHeaders
            )
            if added.enabled, added.looksValid {
                Task { await store.connect(added) }
            }
        }
    }

    // MARK: - 零件

    private func digitsOf(_ text: String) -> String {
        text.filter(\.isNumber)
    }

    private func field(
        _ label: String,
        hint: String,
        text: Binding<String>,
        mono: Bool = false,
        lines: Int = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                hint,
                text: text,
                axis: lines > 1 ? Axis.vertical : Axis.horizontal
            )
            .font(mono ? Font.aevisMono(13) : Font.aevis(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            // 用单值不用范围 —— 三元里写 3...5 : 1...1 容易被解析出歧义
            .lineLimit(lines > 1 ? 5 : 1)
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
