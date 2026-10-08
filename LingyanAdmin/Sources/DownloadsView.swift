import SwiftUI

/// 可下载的文件：列出官网那三个包，并给一个「复制直链」——
/// 链接里带了 `?k=<Key>`，别人浏览器点开就能下，不用再教他填 Key。
struct DownloadsView: View {
    @State private var state: LoadState = .idle
    @State private var items: [DownloadItem] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                StateBanner(state: state) { Task { await load() } }

                if state == .done && items.isEmpty {
                    Text("服务器上还没有可下载的文件")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }

                ForEach(items) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.title.isEmpty ? d.name : d.title)
                            .font(.callout.weight(.medium))
                        if !d.note.isEmpty {
                            Text(d.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Text(Fmt.size(d.size)).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                copyToPasteboard(API.shared.shareURL(d.path), what: "已复制直链")
                            } label: {
                                Label("复制直链", systemImage: "link")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Section {
                    Text("直链形如 …/api/v1/download/\(items.first?.key ?? "plugin")?k=LYAPI-…，把官方下载地址发给别人时用这个。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("下载")
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

    private func load() async {
        state = .loading
        if AppConfig.isDemo {
            items = DemoData.downloads.list("rows").map { DownloadItem(raw: $0) }
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/v1/downloads")
            items = r.list("rows").map { DownloadItem(raw: $0) }
            state = .done
        } catch {
            let e = error as? APIError
            items = []
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
