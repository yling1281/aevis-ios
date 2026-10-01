import SwiftUI

/// 「外接能力」设置卡片 —— 给她接上一台电脑（和那台电脑上连着的手机）。
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
            title("外接能力（电脑）")

            Text("电脑上双击「Aevis 电脑助手」，屏幕上会出现一个 6 位配对码。"
                 + "把它填进来，她的手上就多了一台电脑 —— 能开程序、敲键盘、看屏幕，"
                 + "也能操控那台电脑上用无线调试连着的安卓手机。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            rule

            if store.servers.isEmpty {
                Text("还没加过。先在这台电脑上双击「Aevis 电脑助手」，"
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
                Image(systemName: server.looksLikePC ? "desktopcomputer" : "server.rack")
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
                    Text(server.trimmedURL)
                        .font(.aevisMono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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

            if let line = store.status[server.id] {
                Text(line)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

                Button("删掉") {
                    phones[server.id] = nil
                    store.remove(server)
                }
                .font(.aevis(13))
                .foregroundStyle(.red)

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
        }

        if !status.adbOK {
            Text("电脑上 adb 有点问题：\(status.adbError)")
                .font(.aevis(11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let pairing = status.pairing.first {
            Text("扫到配对端口 \(pairing.text) —— 手机上那个弹窗别关。")
                .font(.aevis(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !status.hint.isEmpty {
            Text(status.hint)
                .font(.aevis(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        }

        if !panel.message.isEmpty {
            Text(panel.message)
                .font(.aevis(11.5))
                .foregroundStyle(panel.messageOK ? Color.green : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(tool.description.isEmpty
                         ? "（那边没写说明）"
                         : String(tool.description.prefix(38)))
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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

    private var addComputerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("电脑上那个窗口里写着两样东西")
                            .font(.aevis(12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("把「局域网地址」和「配对码」照抄进来就行。"
                             + "也可以点下面的「扫码」，直接扫电脑屏幕上那个二维码。")
                            .font(.aevis(11.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    field("电脑地址", hint: "比如 192.168.1.10:\(PCAgent.defaultPort)",
                          text: $draftAddress, mono: true)

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

                    if QRScannerView.isAvailable {
                        Button {
                            sheet = nil
                            scanMode = .addComputer
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "qrcode.viewfinder")
                                Text("扫码（扫电脑屏幕上那个）")
                            }
                            .font(.aevis(13.5, weight: .medium))
                            .foregroundStyle(settings.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(settings.accentColor.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if !addError.isEmpty {
                        Text(addError)
                            .font(.aevis(12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !addStep.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(addStep)
                                .font(.aevis(12))
                                .foregroundStyle(.secondary)
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

            addStep = "在接上她的工具…"
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
            // 用户手改过地址的话，之前记下的电脑主机就不再作数了
            if !draftAddress.isEmpty, let address = PCAgent.parse(draftAddress),
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
