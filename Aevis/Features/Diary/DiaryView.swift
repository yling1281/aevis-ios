import SwiftUI

/// 「日记」—— 两个人写在同一个本子里。
///
/// 用户 2026-10-04：看完电脑版之后要「手机端也同步这些」。
///
/// ⚠️ 密码那一档这次只做「**隐私锁**」：设了密码，进这一页要验证。
///    **不是加密锁** —— 密码就存在本机存档里，"忘了密码永久打不开"那套没做，
///    那是另一件事，别在这里缝进去。
struct DiaryView: View {

    @ObservedObject private var diary = DiaryStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var unlocked = false
    @State private var pinInput = ""
    @State private var pinError: String?
    @State private var editRequest: EditRequest?
    @State private var showPinSheet = false

    /// 打开编辑器用的那点状态。「新增」没有条目，所以不能直接用
    /// `DiaryEntry` 当 `sheet(item:)` 的载体，包一层。
    private struct EditRequest: Identifiable {
        let id = UUID()
        var entry: DiaryEntry
        var isNew: Bool
    }

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    private var canSeeContent: Bool { !diary.hasPin || unlocked }

    var body: some View {
        NavigationStack {
            Group {
                if canSeeContent {
                    content
                } else {
                    lockScreen
                }
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if canSeeContent {
                        toolbarMenu
                    }
                }
            }
            .sheet(item: $editRequest) { request in
                DiaryEditor(
                    original: request.entry,
                    isNew: request.isNew,
                    onSave: { saved in
                        if request.isNew { diary.add(saved) } else { diary.update(saved) }
                    },
                    onDelete: { diary.remove(request.entry.id) }
                )
            }
            .sheet(isPresented: $showPinSheet) {
                DiaryPinSheet()
            }
        }
        .aevisScreen("日记")
    }

    // MARK: - 上锁时的那一屏

    private var lockScreen: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.aevis(30))
                .foregroundStyle(accent)
                .padding(.bottom, 2)

            Text("这个本子上了锁")
                .font(.aevis(17, weight: .semibold))
                .foregroundStyle(.primary)

            Text("输入你设的密码就能翻开。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)

            SecureField("密码", text: $pinInput)
                .font(.aevis(15))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .padding(.horizontal, 36)
                .padding(.top, 4)

            if let pinError {
                Text(pinError)
                    .font(.aevis(12))
                    .foregroundStyle(Color.red)
            }

            Button {
                unlock()
            } label: {
                Text("翻开")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 36)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.top, 52)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 正文

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                if diary.sorted.isEmpty {
                    emptyCard
                } else {
                    ForEach(diary.sorted) { entry in
                        row(entry)
                    }
                }
                privacyNote
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.aevis(17, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .aevisGlass(cornerRadius: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text("和\(taName)的日记")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                Text(diary.sorted.isEmpty ? "还没写过" : "一共 \(diary.sorted.count) 篇")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                startNew()
            } label: {
                Text("写一篇")
                    .font(.aevis(13, weight: .medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .aevisGlass(cornerRadius: 20)
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Text("这里还是空的")
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)
            Text("今天发生了什么、想跟\(taName)说的悄悄话，都可以记在这里。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .aevisGlass(cornerRadius: 20)
    }

    private func row(_ entry: DiaryEntry) -> some View {
        Button {
            editRequest = EditRequest(entry: entry, isNew: false)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(DiaryStore.dayText(entry.date))
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)

                    Text(entry.authorIsMe ? "我写的" : "\(taName)写的")
                        .font(.aevis(10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))

                    if entry.locked {
                        Image(systemName: "lock.fill")
                            .font(.aevis(10))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 6)

                    if let mood = entry.mood, !mood.isEmpty {
                        Text(mood)
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(entry.title.isEmpty ? "（没写标题）" : entry.title)
                    .font(.aevis(15.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !entry.body.isEmpty {
                    Text(entry.body)
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .lineLimit(entry.locked ? 1 : 3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .aevisGlass(cornerRadius: 18)
    }

    private var privacyNote: some View {
        Text(diary.hasPin
             ? "这一页上了锁，密码只存在这台手机上。"
             : "这一页谁打开都能看。想藏起来的话，右上角可以加个密码。")
            .font(.aevis(11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var toolbarMenu: some View {
        Menu {
            Button("写一篇") { startNew() }
            if diary.hasPin {
                Button("改密码") { showPinSheet = true }
                Button("去掉密码", role: .destructive) {
                    diary.setPin("")
                    unlocked = false
                }
            } else {
                Button("加个密码") { showPinSheet = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.aevis(16))
                .foregroundStyle(accent)
        }
    }

    // MARK: - 动作

    private func startNew() {
        editRequest = EditRequest(entry: DiaryEntry(), isNew: true)
    }

    private func unlock() {
        if diary.verify(pinInput) {
            pinError = nil
            pinInput = ""
            unlocked = true
        } else {
            pinError = "密码不对，再想想。"
        }
    }
}

// MARK: - 写 / 改一篇

private struct DiaryEditor: View {

    let original: DiaryEntry
    let isNew: Bool
    var onSave: (DiaryEntry) -> Void
    var onDelete: () -> Void

    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var title: String
    /// ⚠️ 名字**不能叫 `body`** —— 那会和 `View.body` 撞名，直接编译不过。
    @State private var text: String
    @State private var mood: String
    @State private var authorIsMe: Bool
    @State private var locked: Bool

    /// 心情备选 —— 点一下就填进去，也可以自己在上面写。
    private static let moods = ["开心", "平静", "想你", "难过", "期待", "有点累"]

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "ta" : name
    }

    init(original: DiaryEntry,
         isNew: Bool,
         onSave: @escaping (DiaryEntry) -> Void,
         onDelete: @escaping () -> Void) {
        self.original = original
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _date = State(initialValue: original.date)
        _title = State(initialValue: original.title)
        _text = State(initialValue: original.body)
        _mood = State(initialValue: original.mood ?? "")
        _authorIsMe = State(initialValue: original.authorIsMe)
        _locked = State(initialValue: original.locked)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty || !trimmedText.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    authorCard
                    dateCard
                    textCard
                    moodCard
                    lockCard

                    Button {
                        save()
                    } label: {
                        Text(isNew ? "记下来" : "存好")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(canSave ? accent : accent.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)

                    if !isNew {
                        Button {
                            onDelete()
                            dismiss()
                        } label: {
                            Text("删掉这一篇")
                                .font(.aevis(14))
                                .foregroundStyle(Color.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .aevisGlass(cornerRadius: 16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle(isNew ? "写一篇" : "改日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private var authorCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            label("是谁写的")
            HStack(spacing: 6) {
                authorButton(title: "我写的", mine: true)
                authorButton(title: "\(taName)写的", mine: false)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func authorButton(title: String, mine: Bool) -> some View {
        let selected = authorIsMe == mine
        return Button {
            authorIsMe = mine
        } label: {
            Text(title)
                .font(.aevis(13.5, weight: selected ? .semibold : .regular))
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

    private var dateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("哪一天")
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var textCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("标题")
            TextField("今天想写点什么", text: $title)
                .font(.aevis(15))
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            label("正文")
            TextField("慢慢写，写完它就一直在。", text: $text, axis: .vertical)
                .lineLimit(4...12)
                .font(.aevis(14.5))
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var moodCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("心情（可以不写）")
            HStack(spacing: 8) {
                ForEach(Self.moods.prefix(3), id: \.self) { value in
                    moodChip(value)
                }
            }
            HStack(spacing: 8) {
                ForEach(Self.moods.suffix(3), id: \.self) { value in
                    moodChip(value)
                }
            }
            TextField("或者自己写一个", text: $mood)
                .font(.aevis(14))
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func moodChip(_ value: String) -> some View {
        let selected = mood == value
        return Button {
            mood = selected ? "" : value
        } label: {
            Text(value)
                .font(.aevis(13))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(selected ? accent : Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lockCard: some View {
        Toggle(isOn: $locked) {
            VStack(alignment: .leading, spacing: 2) {
                Text("只给自己看")
                    .font(.aevis(14))
                Text("勾上之后，这一篇在列表里只露标题。")
                    .font(.aevis(11))
                    .foregroundStyle(.secondary)
            }
        }
        .tint(accent)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12))
            .foregroundStyle(.secondary)
    }

    private func save() {
        var item = original
        item.date = date
        item.title = trimmedTitle
        item.body = trimmedText
        let trimmedMood = mood.trimmingCharacters(in: .whitespacesAndNewlines)
        item.mood = trimmedMood.isEmpty ? nil : trimmedMood
        item.authorIsMe = authorIsMe
        item.locked = locked
        onSave(item)
        dismiss()
    }
}

// MARK: - 设密码

private struct DiaryPinSheet: View {

    @ObservedObject private var diary = DiaryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var first = ""
    @State private var second = ""
    @State private var note: String?

    private var accent: Color { settings.accentColor }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("给日记本加一把锁")
                            .font(.aevis(14.5, weight: .medium))
                        Text("设好之后，进这一页要先输密码。密码只存在这台手机上，别忘了。")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .aevisGlass(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("输入密码", text: $first)
                            .font(.aevis(15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        SecureField("再输一遍", text: $second)
                            .font(.aevis(15))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 13)
                            .padding(.vertical, 11)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .padding(14)
                    .aevisGlass(cornerRadius: 18)

                    if let note {
                        Text(note)
                            .font(.aevis(12))
                            .foregroundStyle(Color.red)
                            .padding(.horizontal, 4)
                    }

                    Button {
                        save()
                    } label: {
                        Text("就这个密码")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("加个密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func save() {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else {
            note = "先输一个密码吧。"
            return
        }
        guard a == b else {
            note = "两次输的不一样，再看一眼。"
            return
        }
        diary.setPin(a)
        dismiss()
    }
}
