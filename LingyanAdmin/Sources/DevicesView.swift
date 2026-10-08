import SwiftUI

/// 设备授权列表：看谁在用、什么时候到期。
struct DevicesView: View {
    @State private var state: LoadState = .idle
    @State private var items: [DeviceItem] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                StateBanner(state: state) { Task { await load() } }

                if state == .done && items.isEmpty {
                    Text("还没有设备激活过")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }

                ForEach(items) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(d.name.isEmpty ? "（未命名设备）" : d.name)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Chip(text: d.statusLabel, tint: tint(d.status))
                        }
                        Text(d.deviceCode)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 10) {
                            Label(Fmt.time(d.lastSeen), systemImage: "clock")
                            Label(d.expiresAt.isEmpty ? "—" : Fmt.day(d.expiresAt),
                                  systemImage: "calendar.badge.clock")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { copyToPasteboard(d.deviceCode, what: "已复制设备码") }
                }
            }
            .listStyle(.plain)
            .navigationTitle("设备")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func tint(_ status: String) -> Color {
        switch status {
        case "active", "ok", "normal": return .green
        case "expired": return .orange
        case "disabled", "banned": return .red
        default: return .gray
        }
    }

    private func load() async {
        state = .loading
        if AppConfig.isDemo {
            items = DemoData.devices.list("items").map { DeviceItem(raw: $0) }
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/v1/devices")
            items = r.list("items").map { DeviceItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            items = []
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
