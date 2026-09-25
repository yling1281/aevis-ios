import SwiftUI

/// 「MCP」设置卡片 —— 给她外接能力。
///
/// 一句人话解释：你在电脑或服务器上跑一个 MCP 服务，
/// 那边能做的事（读文件、查数据库、控制别的设备）就变成她的工具。
/// 接进来的工具**打字和语音都能用**，因为所有链路走的是同一份工具表。
struct MCPCard: View {

    @ObservedObject private var store = MCPStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var editing: MCPServerConfig?
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var draftHeaders = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("外接能力（MCP）")

            Text("MCP 是「外接能力」。你在电脑或服务器上跑一个 MCP 服务，"
                 + "把它能做的事接进来，她就多几只手 —— 打字和语音都能用。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            rule

            if store.servers.isEmpty {
                Text("还没加过。iOS 上只能连 http 地址的服务 —— "
                     + "App 不能起本地进程，所以服务器得跑在别处（你的电脑、服务器都行）。")
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
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(item: $editing) { server in
            editSheet(server)
        }
    }

    // MARK: - 一行服务器

    private func serverRow(_ server: MCPServerConfig) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(systemName: "server.rack")
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

            HStack(spacing: 16) {
                Button("重连") {
                    Task { await store.connect(server) }
                }
                .font(.aevis(13))
                .foregroundStyle(settings.accentColor)

                Button("改") {
                    draftName = server.name
                    draftURL = server.url
                    draftHeaders = server.headerLines
                    editing = server
                }
                .font(.aevis(13))
                .foregroundStyle(.secondary)

                Button("删掉") {
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

    // MARK: - 添加

    private var addRow: some View {
        Button {
            draftName = ""
            draftURL = ""
            draftHeaders = ""
            editing = MCPServerConfig(name: "", url: "", headerLines: "")
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                    .font(.aevis(14, weight: .medium))
                Text("添加服务器")
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

    // MARK: - 编辑表单

    private func editSheet(_ server: MCPServerConfig) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("名字", hint: "自己认得就行，比如「我电脑」", text: $draftName)
                    field("地址", hint: "http://192.168.1.10:8000/mcp", text: $draftURL)
                    field("请求头（可选）", hint: "Authorization: Bearer xxxxx",
                          text: $draftHeaders, lines: 3)

                    Text("地址要填 MCP 服务暴露的那个端点（通常是 /mcp 或 /sse）。"
                         + "需要认证的服务，把请求头按「名字: 值」的格式一行一个写进去。")
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
                    Button("取消") { editing = nil }
                        .font(.aevis(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .font(.aevis(14, weight: .medium))
                }
            }
        }
    }

    private func save() {
        guard let target = editing else { return }
        editing = nil

        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if store.servers.contains(where: { $0.id == target.id }) {
            var server = target
            server.name = name.isEmpty ? "MCP 服务器" : name
            server.url = url
            server.headerLines = draftHeaders
            store.update(server)
        } else {
            let server = store.add(
                name: name.isEmpty ? "MCP 服务器" : name,
                url: url,
                headerLines: draftHeaders
            )
            if server.enabled, server.looksValid {
                Task { await store.connect(server) }
            }
        }
    }

    private func field(
        _ label: String,
        hint: String,
        text: Binding<String>,
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
            .font(.aevisMono(13))
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

    // MARK: - 零件

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
