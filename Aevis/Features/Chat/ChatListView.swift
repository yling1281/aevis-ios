import SwiftUI

/// 会话列表 —— 微信的第一个 tab。
///
/// 点一行就进那个人的聊天页。因为 `ChatView` 读的是「当前联系人」，
/// 所以在推页面之前先把人切过去。
struct ChatListView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var chat = ChatStore.shared
    /// 界面密度要生效，所以得订阅设置（改完回来立刻就能看到变化）
    @ObservedObject private var settings = AppSettings.shared

    @State private var path: [UUID] = []
    @State private var adding = false
    /// 加号菜单里的「扫一扫 · 配对电脑版」。
    @State private var pairing = false
    /// ⭐ 群聊。观察它，新建 / 删群后列表立刻跟着变。
    @ObservedObject private var groups = GroupStore.shared
    /// 加号菜单里的「新建群聊」—— 用 overlay 呈现，不用第三个 `.sheet`。
    @State private var creatingGroup = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if personaStore.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("聊天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 加号从「直接建联系人」变成**菜单** —— 跟微信同一个位置、
                    // 同一个手感（老板 2026-10-02 要求的「移动端加号扫码登录」）。
                    Menu {
                        Button {
                            pairing = true
                        } label: {
                            Label("扫一扫 · 配对电脑版", systemImage: "qrcode.viewfinder")
                        }
                        .disabled(!QRScannerView.isAvailable)

                        Button {
                            adding = true
                        } label: {
                            Label("新建联系人", systemImage: "person.badge.plus")
                        }

                        Button {
                            creatingGroup = true
                        } label: {
                            Label("新建群聊", systemImage: "person.2.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.aevis(16, weight: .semibold))
                    }
                }
            }
            .navigationDestination(for: UUID.self) { _ in
                ChatView()
                    .aevisScreen("聊天")
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                PersonaEditorView(adding: true)
                    .environmentObject(personaStore)
            }
        }
        .sheet(isPresented: $pairing) {
            // ⚠️ 用**同一个** `PairScanView` —— 授权的逻辑只此一份。
            //    这里再写一遍"扫到之后怎么办"，改口径时一定会漏一个入口。
            PairScanView()
        }
        // 新建群聊：**用 overlay、不加第三个 `.sheet`** ——
        // 本视图上已经挂着两个 `.sheet`（新建联系人 / 配对），本项目实测
        // 「同一个视图叠多个 `.sheet` 只认最后一个」，再叠第三个会静默失效。
        // `.overlay` 走普通视图合成、不碰 SwiftUI 的呈现系统（跟 `MainTabView` 里
        // 那几处同一个理由）。
        .overlay {
            if creatingGroup {
                GroupEditorView(onClose: { creatingGroup = false })
                    .transition(.move(edge: .bottom))
                    .zIndex(50)
            }
        }
        // 截图自检：直接进第一个联系人的对话（否则截不到聊天页本身）
        .onAppear {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("-aevisOpenChat"),
                  path.isEmpty,
                  let first = personaStore.contacts.first else { return }
            open(first)
            #endif
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                // ⭐ 群聊排在最上面（跟微信一致）。
                ForEach(groups.groups) { group in
                    Button {
                        open(group)
                    } label: {
                        groupRow(group)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(personaStore.contacts) { contact in
                    Button {
                        open(contact)
                    } label: {
                        row(contact)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func open(_ contact: Contact) {
        personaStore.select(contact.id)
        path.append(contact.id)
    }

    /// 进一个群。
    ///
    /// 群和联系人**共用一套会话机制** —— 把当前会话切到群，再推聊天页即可。
    /// ⚠️ **不要**调 `personaStore.select`：群不是联系人，切过去会把当前联系人搞乱。
    private func open(_ group: ChatGroup) {
        ChatStore.shared.switchTo(group.id)
        path.append(group.id)
    }

    private func groupRow(_ group: ChatGroup) -> some View {
        HStack(spacing: 12) {
            GroupAvatarBadge(size: 46, memberCount: group.memberCount)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.aevis(15.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(groupPreview(group))
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(groupStamp(group))
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11 * CGFloat(settings.densityScale))
        .aevisGlass(cornerRadius: 18)
        .contentShape(Rectangle())
    }

    /// 群的预览行：有发言人就带上名字（「A：…」），跟微信一样。
    private func groupPreview(_ group: ChatGroup) -> String {
        let fallback = "\(group.memberCount) 个成员"
        guard let last = chat.lastMessage(for: group.id) else { return fallback }
        let text = last.previewText.replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return fallback }
        if let name = last.speakerName, !name.isEmpty, last.role != .user {
            return "\(name)：\(text)"
        }
        return last.role == .user ? "我：\(text)" : text
    }

    private func groupStamp(_ group: ChatGroup) -> String {
        guard let last = chat.lastMessage(for: group.id) else { return "" }
        return RelativeTime.label(for: last.date)
    }

    private func row(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            AevisAvatar(
                size: 46,
                seed: contact.persona.avatarSeed,
                image: personaStore.avatar(for: contact.id)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.aevis(15.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(preview(contact))
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(stamp(contact))
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        // 行高跟着界面密度走（紧凑 / 标准 / 宽松）
        .padding(.vertical, 11 * CGFloat(settings.densityScale))
        .aevisGlass(cornerRadius: 18)
        .contentShape(Rectangle())
    }

    /// 最后一条说了什么。微信会在自己发的前面加「我：」。
    private func preview(_ contact: Contact) -> String {
        guard let last = chat.lastMessage(for: contact.id) else { return "还没聊过" }
        let text = last.previewText
            .replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty else { return "还没聊过" }
        return last.role == .user ? "我：\(text)" : text
    }

    private func stamp(_ contact: Contact) -> String {
        guard let last = chat.lastMessage(for: contact.id) else { return "" }
        return RelativeTime.label(for: last.date)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            AevisOrb()
                .scaleEffect(0.72)
            Text("还没有联系人")
                .font(.aevis(17, weight: .medium))
                .foregroundStyle(.primary)
            Text("去「通讯录」加一个，再回来聊。")
                .font(.aevis(13.5))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity)
    }
}


/// 新建群聊：起个名字 + 从通讯录里勾至少 2 个人。
///
/// ⚠️ 它是用 **`.overlay`** 从 `ChatListView` 弹出来的，**不是 `.sheet`** ——
///    那个视图上已经有两个 sheet 了，本项目实测「同视图多个 sheet 只认最后一个」。
///    所以这个编辑器自己**完整**带一层 `NavigationStack` + 取消 / 创建按钮，
///    因为它不是 sheet、没有系统给的关闭手势。
struct GroupEditorView: View {
    @ObservedObject private var personaStore = PersonaStore.shared

    /// 关掉自己（由父视图切开关）。
    var onClose: () -> Void

    @State private var name = ""
    @State private var selected: Set<UUID> = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section("群名") {
                    TextField("给这个群起个名字", text: $name)
                }
                Section("群成员（至少选 2 个）") {
                    if personaStore.contacts.isEmpty {
                        Text("通讯录里还没有联系人。先去「通讯录」加一个，再回来建群。")
                            .font(.aevis(14))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(personaStore.contacts) { contact in
                        Button {
                            toggle(contact.id)
                        } label: {
                            HStack(spacing: 12) {
                                AevisAvatar(size: 36,
                                            seed: contact.persona.avatarSeed,
                                            image: personaStore.avatar(for: contact.id))
                                Text(contact.displayName)
                                    .font(.aevis(15))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Image(systemName: selected.contains(contact.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.aevis(18))
                                    .foregroundStyle(selected.contains(contact.id)
                                                     ? AppSettings.shared.accentColor
                                                     : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.aevis(13))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建群聊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") { create() }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selected.count >= 2
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    private func create() {
        // 按通讯录顺序取，保证发言顺序稳定（不是 Set 的随机序）。
        let members = personaStore.contacts.map { $0.id }.filter { selected.contains($0) }
        guard GroupStore.shared.create(name: name, memberIDs: members) != nil else {
            errorText = "名字不能空，而且至少要选 2 个成员。"
            return
        }
        onClose()
    }
}
