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
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.aevis(16, weight: .semibold))
                    }
                }
            }
            .navigationDestination(for: UUID.self) { _ in
                ChatView()
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                PersonaEditorView(adding: true)
                    .environmentObject(personaStore)
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
