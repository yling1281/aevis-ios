import SwiftUI
import UniformTypeIdentifiers

/// 记忆库本体：能看、能改、能删、能备份。
///
/// 备份走两条路：
/// - **导出文件** —— 存到「文件」App，你自己决定放哪（网盘也行）
/// - **本地快照** —— App 自己留最近 20 份，出事了直接恢复
///
/// 百度网盘那条路留了接口但没接（`CloudBackup`），界面里如实写「未接入」，
/// 不假装能用。
struct MemoryListView: View {
    @ObservedObject private var memory = MemoryStore.shared

    @State private var adding = false
    @State private var newText = ""
    @State private var newKind: MemoryItem.Kind = .fact

    @State private var editing: MemoryItem?
    @State private var editText = ""

    @State private var exporting = false
    @State private var importing = false
    @State private var exportDocument = JSONBackupDocument(data: Data())
    @State private var showClearConfirm = false
    @State private var restoring: URL?

    var body: some View {
        List {
            if memory.items.isEmpty {
                Section {
                    Text("还什么都没记住。聊几轮，或者自己加一条。")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(MemoryItem.Kind.allCases) { kind in
                    let group = memory.items.filter { $0.kind == kind }
                    if !group.isEmpty {
                        Section(kind.label) {
                            ForEach(group) { item in
                                row(item)
                            }
                        }
                    }
                }
            }

            Section("备份") {
                Button {
                    prepareExport()
                } label: {
                    Label("导出一份备份", systemImage: "square.and.arrow.up")
                }
                .disabled(memory.items.isEmpty)

                Button {
                    importing = true
                } label: {
                    Label("从备份恢复", systemImage: "square.and.arrow.down")
                }

                Button {
                    memory.snapshot()
                } label: {
                    Label("存一份本地快照", systemImage: "camera.on.rectangle")
                }
                .disabled(memory.items.isEmpty)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空记忆库", systemImage: "trash")
                }
                .disabled(memory.items.isEmpty)
            }

            let snaps = memory.snapshots()
            if !snaps.isEmpty {
                Section("本地快照（最近 20 份）") {
                    ForEach(snaps, id: \.url) { entry in
                        snapshotRow(entry)
                    }
                }
            }

            Section("云端") {
                HStack {
                    Label("百度网盘", systemImage: "cloud")
                    Spacer(minLength: 8)
                    Text("未接入")
                        .font(.aevis(12.5))
                        .foregroundStyle(.tertiary)
                }
                Text("这条通道留好了接口，等接上之后备份能直接传网盘。现在先用「导出」存到「文件」里。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("记忆库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newText = ""
                    newKind = .fact
                    adding = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("加一条记忆", isPresented: $adding) {
            TextField("比如：他住在杭州，晚上容易失眠", text: $newText, axis: .vertical)
            Button("记住") {
                memory.add(newText, kind: newKind)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(Pronoun.current)会一直记得这条。")
        }
        .alert("改这条记忆", isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            TextField("内容", text: $editText, axis: .vertical)
            Button("保存") {
                if var item = editing {
                    item.text = editText
                    memory.update(item)
                }
                editing = nil
            }
            Button("取消", role: .cancel) { editing = nil }
        }
        .confirmationDialog(
            "清空整个记忆库？",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { memory.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(Pronoun.current)会忘掉这些事。建议先导出一份备份。")
        }
        .confirmationDialog(
            "用这份快照覆盖现在的记忆？",
            isPresented: Binding(
                get: { restoring != nil },
                set: { if !$0 { restoring = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                if let url = restoring { memory.restore(snapshot: url) }
                restoring = nil
            }
            Button("取消", role: .cancel) { restoring = nil }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "aevis-memory"
        ) { result in
            switch result {
            case .success:
                memory.statusLine = "备份已导出。"
            case .failure(let error):
                memory.statusLine = "导出失败：\(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    memory.statusLine = "这个文件读不出来。"
                    return
                }
                memory.importData(data)
            case .failure(let error):
                memory.statusLine = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 行

    private func row(_ item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .font(.aevis(13))
                .foregroundStyle(AppSettings.shared.accentColor)
                .frame(width: 20)
                .padding(.top, 2)

            Text(item.text)
                .font(.aevis(14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            Button {
                memory.togglePin(item)
            } label: {
                Image(systemName: item.pinned ? "pin.fill" : "pin")
                    .font(.aevis(13))
                    .foregroundStyle(item.pinned ? AppSettings.shared.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            editText = item.text
            editing = item
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                memory.remove(item)
            } label: {
                Label("删掉", systemImage: "trash")
            }
        }
    }

    private func snapshotRow(_ entry: (name: String, url: URL, date: Date, size: Int)) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.stamp(entry.date))
                    .font(.aevis(13.5))
                    .foregroundStyle(.primary)
                Text("\(entry.size / 1024) KB · \(entry.name)")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("恢复") { restoring = entry.url }
                .font(.aevis(13))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                memory.delete(snapshot: entry.url)
            } label: {
                Label("删掉", systemImage: "trash")
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    // MARK: - 导出

    private func prepareExport() {
        guard let data = memory.exportData() else {
            memory.statusLine = "导出失败：生成备份数据出错。"
            return
        }
        exportDocument = JSONBackupDocument(data: data)
        exporting = true
    }
}

/// 备份文件。就是一份 JSON，用什么工具都能看。
struct JSONBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
