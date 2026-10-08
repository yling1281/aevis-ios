import SwiftUI

/// 素材列表：搜索（防抖）、按分类筛、点进去看详情。
struct MaterialsView: View {
    @State private var state: LoadState = .idle
    @State private var items: [MaterialItem] = []
    @State private var total = 0
    @State private var kw = ""
    @State private var category = ""
    @State private var showSettings = false

    private static let pageLimit = 200

    var body: some View {
        NavigationStack {
            List {
                StateBanner(state: state) { Task { await load() } }

                if state == .done && items.isEmpty {
                    Text("没有匹配的素材")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                }

                ForEach(items) { m in
                    NavigationLink {
                        MaterialDetailView(item: m)
                    } label: {
                        row(m)
                    }
                }

                if total > items.count {
                    Text("只显示了前 \(items.count) 条，共 \(total) 条（可以搜索缩小范围）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .navigationTitle("素材")
            .searchable(text: $kw, prompt: "搜索文件名 / 分类 / 标签")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("全部分类") { category = "" }
                        Button("角色") { category = "角色" }
                        Button("场景") { category = "场景" }
                        Button("动作") { category = "动作" }
                        Button("特效") { category = "特效" }
                        Button("UI") { category = "UI" }
                        Button("表情包") { category = "表情包" }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable { await load() }
            // task(id:) 在 kw/category 变化时会取消上一轮 —— 天然防抖，不用手写 Timer
            .task(id: kw + "|" + category) {
                try? await Task.sleep(nanoseconds: 320_000_000)
                if Task.isCancelled { return }
                await load()
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    @ViewBuilder
    private func row(_ m: MaterialItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper")
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.filename)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if !m.category.isEmpty { Chip(text: m.category) }
                    Text(Fmt.size(m.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                    if !m.tags.isEmpty {
                        Text(m.tags.prefix(2).map { "#" + $0 }.joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        state = .loading
        if AppConfig.isDemo {
            let raw = DemoData.materials
            items = raw.list("items").map { MaterialItem(raw: $0) }
            total = raw.i("total")
            state = .done
            return
        }
        do {
            let r = try await API.shared.get("/api/v1/materials", query: [
                "search": kw,
                "category": category,
                "limit": "\(Self.pageLimit)",
                "offset": "0",
            ])
            items = r.list("items").map { MaterialItem(raw: $0) }
            total = r.i("total")
            state = .done
        } catch {
            let e = error as? APIError
            items = []
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}

/// 素材详情：字段全列出来，链接可以点、可以复制。
struct MaterialDetailView: View {
    let item: MaterialItem

    var body: some View {
        List {
            Section {
                Text(item.filename)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            }
            Section("信息") {
                KVRow(k: "编号", v: "#\(item.id)")
                KVRow(k: "分类", v: item.category)
                KVRow(k: "大小", v: Fmt.size(item.sizeBytes))
                KVRow(k: "标签", v: item.tags.map { "#" + $0 }.joined(separator: "  "))
                KVRow(k: "作者", v: item.author)
                KVRow(k: "来源", v: item.source)
                KVRow(k: "授权", v: item.license)
                KVRow(k: "入库", v: Fmt.time(item.createdAt))
                KVRow(k: "更新", v: Fmt.time(item.updatedAt))
            }
            if !item.sourceURL.isEmpty {
                Section("来源链接") {
                    Text(item.sourceURL)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                        .textSelection(.enabled)
                    Button("复制链接") { copyToPasteboard(item.sourceURL, what: "已复制链接") }
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("素材详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
