import SwiftUI

/// 「情侣空间」—— 在一起多少天 + 倒数日。
///
/// 用户原话（2026-10-01）：「情侣空间倒数日，你写代码呀。
/// 倒数日可以自己添加情侣空间，也可以绑定情侣」。
///
/// 这一屏只管**现在正在聊的那个 TA**：换联系人 = 换一套
/// （数据在 `CoupleStore` 里按联系人分开存）。
///
/// ⚠️ 倒数日和「绑定情侣」是**两件独立的事**：
///    · 倒数日谁都能用，不用先绑定（生日、考试、见面都算）；
///    · 绑定只是给这一屏顶上补一行「在一起第 N 天」。
struct CoupleSpaceView: View {

    @ObservedObject private var couple = CoupleStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var profile = ProfileStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showBind = false
    @State private var editRequest: EditRequest?

    /// 打开编辑器用的那点状态。「新增」没有 item，所以不能直接用
    /// `Anniversary` 当 `sheet(item:)` 的载体，包一层。
    private struct EditRequest: Identifiable {
        let id = UUID()
        var item: Anniversary
        var isNew: Bool
    }

    private var accent: Color { settings.accentColor }

    private var taName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "TA" : name
    }

    private var myName: String {
        let name = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "我" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    list

                    Text("这一屏的东西只存在这台手机上，也不会跟着通讯录里的人走。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("情侣空间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showBind) {
            BindSheet(
                current: couple.togetherSince,
                onSave: { couple.bind(since: $0) },
                onUnbind: { couple.unbind() }
            )
        }
        .sheet(item: $editRequest) { request in
            AnniversaryEditor(
                original: request.item,
                isNew: request.isNew,
                onSave: { saved in
                    if request.isNew { couple.add(saved) } else { couple.update(saved) }
                },
                onDelete: { couple.remove(request.item.id) }
            )
        }
    }

    // MARK: - 上面那张卡

    private var hero: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                AevisAvatar(source: .me, size: 56)
                Image(systemName: "heart.fill")
                    .font(.aevis(14))
                    .foregroundStyle(accent.opacity(0.9))
                AevisAvatar(source: .ai, size: 56, seed: personaStore.persona.avatarSeed)
            }

            HStack(spacing: 6) {
                Text(myName)
                    .font(.aevis(13.5, weight: .medium))
                    .lineLimit(1)
                Text("·")
                    .font(.aevis(13))
                    .foregroundStyle(.tertiary)
                Text(taName)
                    .font(.aevis(13.5, weight: .medium))
                    .lineLimit(1)
            }

            if let days = couple.daysTogether {
                VStack(spacing: 3) {
                    Text("我们已经在一起")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(days)")
                            .font(.aevis(42, weight: .semibold))
                            .foregroundStyle(accent)
                        Text("天")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let since = couple.togetherSince {
                        Text("从 \(CoupleStore.dayText(since)) 开始")
                            .font(.aevis(11.5))
                            .foregroundStyle(.tertiary)
                    }
                }

                Button {
                    showBind = true
                } label: {
                    Text("改一下日子")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 5) {
                    Text("还没绑定情侣")
                        .font(.aevis(14, weight: .medium))
                    Text("绑定之后，这里会显示你们在一起多少天。")
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showBind = true
                } label: {
                    Text("绑定情侣")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(.white)
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .aevisGlass(cornerRadius: 22)
    }

    // MARK: - 倒数日

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("倒数日")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !couple.anniversaries.isEmpty {
                    Text("\(couple.anniversaries.count) 个")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    startNew()
                } label: {
                    Image(systemName: "plus")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .aevisGlass(cornerRadius: 11)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if couple.anniversaries.isEmpty {
                Text("还没有。点右上角那个加号添一个 —— 生日、周年、下次见面的日子都行。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ForEach(couple.upcoming) { item in
                    row(item)
                }
                Text("点一条可以改或删。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func row(_ item: Anniversary) -> some View {
        let days = item.daysLeft()
        let isToday = days == 0
        // 已过去的那些用灰的 —— 一眼就能把"还要等的"和"已经过去的"分开。
        let tone: Color = days < 0 ? Color.secondary : accent

        return Button {
            editRequest = EditRequest(item: item, isNew: false)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 1) {
                    if isToday {
                        Text("今天")
                            .font(.aevis(13, weight: .semibold))
                            .foregroundStyle(tone)
                    } else {
                        Text("\(abs(days))")
                            .font(.aevis(18, weight: .semibold))
                            .foregroundStyle(tone)
                        Text(days > 0 ? "天" : "天前")
                            .font(.aevis(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 50, height: 50)
                .background(Circle().fill(tone.opacity(0.13)))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        // ⚠️ 传 String 而不是 LocalizedStringKey —— 标题是用户/模型
                        //    随手写的，里面真出现星号就该原样显示，不该被当 markdown。
                        Text(item.title)
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if item.byAI {
                            Text("TA 加的")
                                .font(.aevis(9.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                    Text(subtitle(item))
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ item: Anniversary) -> String {
        var text = CoupleStore.dayText(item.date)
        if item.yearly { text += " · 每年" }
        if !item.note.isEmpty { text += " · \(item.note)" }
        return text
    }

    // MARK: - 动作

    private func startNew() {
        editRequest = EditRequest(item: Anniversary(), isNew: true)
    }
}

// MARK: - 绑定情侣

/// 设「在一起」的第一天。
private struct BindSheet: View {

    let current: Date?
    var onSave: (Date) -> Void
    var onUnbind: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()

    private var accent: Color { settings.accentColor }
    private var isBound: Bool { current != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("你们是哪天在一起的？")
                            .font(.aevis(14.5, weight: .medium))
                        Text("选错了随时能改。只要日子对，剩下的天数 App 自己算。")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .aevisGlass(cornerRadius: 18)

                    DatePicker("在一起的日子",
                               selection: $date,
                               // 未来的日子不算"在一起" —— 直接不给选。
                               in: Date.distantPast...Date(),
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .font(.aevis(14))
                        .tint(accent)
                        .padding(12)
                        .aevisGlass(cornerRadius: 18)

                    Button {
                        onSave(date)
                        dismiss()
                    } label: {
                        Text(isBound ? "改成这一天" : "就这样")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(accent)
                            )
                    }
                    .buttonStyle(.plain)

                    if isBound {
                        Button {
                            onUnbind()
                            dismiss()
                        } label: {
                            Text("解除绑定")
                                .font(.aevis(14))
                                .foregroundStyle(.red)
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
            .navigationTitle("绑定情侣")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // 已经绑过就停在原来那天，别让用户以为要重选一次。
                if let current { date = current }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 加 / 改一条倒数日

private struct AnniversaryEditor: View {

    let original: Anniversary
    let isNew: Bool
    var onSave: (Anniversary) -> Void
    var onDelete: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var date: Date
    @State private var yearly: Bool
    @State private var note: String

    private var accent: Color { settings.accentColor }

    init(original: Anniversary,
         isNew: Bool,
         onSave: @escaping (Anniversary) -> Void,
         onDelete: @escaping () -> Void) {
        self.original = original
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: original.title)
        _date = State(initialValue: original.date)
        _yearly = State(initialValue: original.yearly)
        _note = State(initialValue: original.note)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        label("是什么日子")
                        TextField("比如：TA 的生日", text: $title)
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

                    VStack(alignment: .leading, spacing: 10) {
                        label("哪一天")
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .tint(accent)

                        Divider().opacity(0.4)

                        Toggle(isOn: $yearly) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("每年重复")
                                    .font(.aevis(14))
                                Text("生日、周年这种 —— 过完今年会自动算明年。")
                                    .font(.aevis(11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(accent)
                    }
                    .padding(14)
                    .aevisGlass(cornerRadius: 18)

                    VStack(alignment: .leading, spacing: 8) {
                        label("备注（可以不写）")
                        TextField("说点什么…", text: $note, axis: .vertical)
                            .lineLimit(1...3)
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

                    Button {
                        var item = original
                        item.title = trimmedTitle
                        item.date = date
                        item.yearly = yearly
                        item.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(item)
                        dismiss()
                    } label: {
                        Text(isNew ? "加上" : "保存")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(accent.opacity(trimmedTitle.isEmpty ? 0.4 : 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedTitle.isEmpty)

                    if !isNew {
                        Button {
                            onDelete()
                            dismiss()
                        } label: {
                            Text("删掉这条")
                                .font(.aevis(14))
                                .foregroundStyle(.red)
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
            .navigationTitle(isNew ? "加一个倒数日" : "改倒数日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12))
            .foregroundStyle(.secondary)
    }
}
