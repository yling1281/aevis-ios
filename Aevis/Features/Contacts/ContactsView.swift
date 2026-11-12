import SwiftUI

/// 通讯录 —— 微信的第二个 tab。
///
/// 用户要的「可以自己加联系人」就在这儿：右上角加号新建，
/// 每行右边的「…」能编辑资料或者删掉。
struct ContactsView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var settings = AppSettings.shared

    @State private var path: [UUID] = []
    @State private var adding = false
    @State private var editing = false
    @State private var pendingDelete: Contact?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                V2TopBar(title: "通讯录", subtitle: subtitle) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.aevis(15, weight: .semibold))
                            .foregroundStyle(V2.accent)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(V2.soft(0.13)))
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(spacing: 14) {
                        if personaStore.contacts.isEmpty {
                            V2Empty("通讯录里还没有人", hint: "点右上角 + 建一个，或者去「发现」挑一个")
                        } else {
                            V2Card {
                                ForEach(personaStore.contacts.indices, id: \.self) { i in
                                    let contact = personaStore.contacts[i]
                                    row(contact)
                                    if i < personaStore.contacts.count - 1 {
                                        V2Divider(leading: 76)
                                    }
                                }
                            }
                        }

                        addRow
                    }
                    .padding(.horizontal, V2.gutter)
                    .padding(.bottom, 18)
                }
            }
            .v2Page()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { _ in
                ChatView()
            }
            .sheet(isPresented: $adding) {
                NavigationStack {
                    PersonaEditorView(adding: true)
                        .environmentObject(personaStore)
                }
            }
            .sheet(isPresented: $editing) {
                NavigationStack {
                    PersonaEditorView(isFirstRun: false)
                        .environmentObject(personaStore)
                }
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: deleteBinding,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) { confirmDelete() }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("ta 的人设、聊天记录、记忆和朋友圈都会一起删掉，不能撤销。")
            }
        }
    }

    private var subtitle: String {
        let n = personaStore.contacts.count
        return n == 0 ? "还没加人" : "\(n) 个人"
    }

    // MARK: - 一行

    private func row(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            Button {
                open(contact)
            } label: {
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
                        Text(detail(contact))
                            .font(.aevis(12))
                            .foregroundStyle(V2.dim(0.45))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    edit(contact)
                } label: {
                    Label("编辑资料", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = contact
                } label: {
                    Label("删除联系人", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(V2.dim(0.4))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, V2.gutter)
        .padding(.vertical, 12)
    }

    /// 第二行那点信息：性别 · 关系 · 性格，有个大概就够。
    private func detail(_ contact: Contact) -> String {
        let persona = contact.persona
        var parts: [String] = []
        if persona.gender != .unspecified { parts.append(persona.gender.label) }

        let relationship = persona.relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        if !relationship.isEmpty { parts.append(relationship) }

        let personality = persona.personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personality.isEmpty { parts.append(personality) }

        return parts.isEmpty ? "还没设置性格" : parts.joined(separator: " · ")
    }

    private var addRow: some View {
        Button {
            adding = true
        } label: {
            HStack(spacing: 13) {
                V2IconBox("plus")
                Text("添加联系人")
                    .font(.aevis(V2.body, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(V2.dim(0.22))
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                    .fill(V2.accent.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                    .strokeBorder(V2.accent.opacity(0.14), lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func open(_ contact: Contact) {
        personaStore.select(contact.id)
        path.append(contact.id)
    }

    private func edit(_ contact: Contact) {
        personaStore.select(contact.id)
        editing = true
    }

    private func confirmDelete() {
        if let contact = pendingDelete {
            personaStore.remove(contact.id)
        }
        pendingDelete = nil
    }

    private var deleteTitle: String {
        guard let contact = pendingDelete else { return "删除这个联系人？" }
        return "删除「\(contact.displayName)」？"
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { shown in if !shown { pendingDelete = nil } }
        )
    }
}
