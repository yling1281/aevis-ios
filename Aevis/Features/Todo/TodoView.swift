import SwiftUI

/// 「一起做的事」—— 温馨那一挂的清单，不是任务管理器。
///
/// 用户 2026-10-04：看完电脑版之后要「手机端也同步这些」。
struct TodoView: View {

    @ObservedObject private var todo = TodoStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var noteDraft = ""
    @State private var composeExpanded = false
    @State private var editRequest: EditRequest?

    private struct EditRequest: Identifiable {
        let id = UUID()
        var item: TodoItem
    }

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    compose
                    list
                    footNote
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("一起做的事")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $editRequest) { request in
                TodoEditor(
                    original: request.item,
                    onSave: { todo.update($0) },
                    onDelete: { todo.remove(request.item.id) }
                )
            }
        }
        .aevisScreen("一起做的事")
    }

    // MARK: - 顶上一行

    private var hero: some View {
        HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.aevis(17, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .aevisGlass(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("和\(taName)的清单")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(heroLine)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .aevisGlass(cornerRadius: 20)
    }

    private var heroLine: String {
        if todo.items.isEmpty { return "想一起做的事，都写在这儿" }
        if todo.openCount == 0 { return "都做完啦，再看看下一件" }
        return "还有 \(todo.openCount) 件等着一起做"
    }

    // MARK: - 加一件

    private var compose: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("想和\(taName)一起做点什么", text: $draft)
                    .font(.aevis(14.5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .onSubmit { addItem() }

                Button {
                    withAnimation(.snappy(duration: 0.2)) { composeExpanded.toggle() }
                } label: {
                    Image(systemName: composeExpanded ? "chevron.up" : "chevron.down")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .aevisGlass(cornerRadius: 12)
                }
                .buttonStyle(.plain)
            }

            if composeExpanded {
                TextField("附一句（可以不写）", text: $noteDraft, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.aevis(13.5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            Button {
                addItem()
            } label: {
                Text("加进清单")
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(trimmedDraft.isEmpty ? accent.opacity(0.4) : accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(trimmedDraft.isEmpty)
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 清单

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if todo.items.isEmpty {
                Text("还没有。写一件你们一直想做、又总拖着的事，做完打个勾。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else {
                ForEach(todo.ordered) { item in
                    todoRow(item)
                }
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func todoRow(_ item: TodoItem) -> some View {
        HStack(spacing: 12) {
            Button {
                todo.toggle(item.id)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.aevis(19))
                    .foregroundStyle(item.done ? accent : Color.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
                    .strikethrough(item.done, color: Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.note.isEmpty {
                    Text(item.note)
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if !item.byMe {
                Text("\(taName)提的")
                    .font(.aevis(9.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button("改一下") {
                editRequest = EditRequest(item: item)
            }
            Button(item.done ? "改成没做" : "标记做完") {
                todo.toggle(item.id)
            }
            Button("删掉", role: .destructive) {
                todo.remove(item.id)
            }
        }
    }

    private var footNote: some View {
        Text("这一页只记你们俩的事，不会提醒、不会催你 —— 想起来就来看一眼。")
            .font(.aevis(11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 动作

    private func addItem() {
        guard !trimmedDraft.isEmpty else { return }
        var item = TodoItem()
        item.title = trimmedDraft
        item.note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        item.byMe = true
        todo.add(item)
        draft = ""
        noteDraft = ""
        composeExpanded = false
    }
}

// MARK: - 改一件

private struct TodoEditor: View {

    let original: TodoItem
    var onSave: (TodoItem) -> Void
    var onDelete: () -> Void

    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var note: String
    @State private var byMe: Bool

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    init(original: TodoItem,
         onSave: @escaping (TodoItem) -> Void,
         onDelete: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: original.title)
        _note = State(initialValue: original.note)
        _byMe = State(initialValue: original.byMe)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("要做的事")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                        TextField("想一起做点什么", text: $title)
                            .font(.aevis(15))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .padding(14)
                    .aevisGlass(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("附一句（可以不写）")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                        TextField("比如：下周三之前", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.aevis(14))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .padding(14)
                    .aevisGlass(cornerRadius: 18)

                    HStack(spacing: 6) {
                        whoButton(title: "我提的", mine: true)
                        whoButton(title: "\(taName)提的", mine: false)
                    }
                    .padding(3)
                    .aevisGlass(cornerRadius: 14)

                    Button {
                        var item = original
                        item.title = trimmedTitle
                        item.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        item.byMe = byMe
                        onSave(item)
                        dismiss()
                    } label: {
                        Text("存好")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(trimmedTitle.isEmpty ? accent.opacity(0.4) : accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedTitle.isEmpty)

                    Button {
                        onDelete()
                        dismiss()
                    } label: {
                        Text("删掉这件")
                            .font(.aevis(14))
                            .foregroundStyle(Color.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .aevisGlass(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("改一件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func whoButton(title: String, mine: Bool) -> some View {
        let selected = byMe == mine
        return Button {
            byMe = mine
        } label: {
            Text(title)
                .font(.aevis(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
