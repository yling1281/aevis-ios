// 选人弹层（2026-11-12）
//
// 用户：「听音乐可以选择是谁，发朋友圈是所有人一起同时发，情侣空间也可以选择谁，
//       一起做的事也可以选择哪个人，一起听也可以选择分享给谁……
//       很多东西其实都只是一个人一个 UI，每个东西其实都是要选」。
//
// 之前大量功能直接吃 `PersonaStore.shared.persona`（= 当前活跃的那个人），
// 界面上根本没有"选谁"这一步。这里给一个统一的选人层，各处都复用它。
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - 单选

/// 选一个人。选完直接回调并关闭。
struct PersonaPicker: View {
    var title: String = "选一个人"
    var subtitle: String? = nil
    /// 默认把当前活跃的那个标成"当前"。
    var showsCurrent: Bool = true
    var onPick: (UUID) -> Void

    @ObservedObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.contacts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.contacts) { contact in
                                Button {
                                    onPick(contact.id)
                                    dismiss()
                                } label: {
                                    row(contact)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(V2.gutter)
                    }
                }
            }
            .background(V2.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func row(_ contact: Contact) -> some View {
        HStack(spacing: 12) {
            avatar(contact, size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(contact.displayName)
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(.primary)
                if !contact.persona.relationship.isEmpty {
                    Text(contact.persona.relationship)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if showsCurrent, store.active?.id == contact.id {
                Text("当前")
                    .font(.aevis(10.5, weight: .medium))
                    .foregroundStyle(V2.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(V2.soft(0.14)))
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(V2.dim(0.3))
        }
        .padding(12)
        .background(V2.card, in: RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                .stroke(V2.stroke, lineWidth: 0.5)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(V2.dim(0.3))
            Text("还没有人，先去通讯录加一个")
                .font(.aevis(13))
                .foregroundStyle(V2.dim(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func avatar(_ contact: Contact, size: CGFloat) -> some View {
        #if canImport(UIKit)
        if let img = store.avatar(for: contact.id) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(Circle())
        } else {
            fallbackAvatar(contact, size: size)
        }
        #else
        fallbackAvatar(contact, size: size)
        #endif
    }

    private func fallbackAvatar(_ contact: Contact, size: CGFloat) -> some View {
        Circle()
            .fill(V2.soft(0.16))
            .frame(width: size, height: size)
            .overlay(
                Text(String(contact.displayName.prefix(1)))
                    .font(.aevis(size * 0.42, weight: .medium))
                    .foregroundStyle(V2.accent)
            )
    }
}

// MARK: - 多选

/// 选多个人（朋友圈"一起发"用）。
struct PersonaMultiPicker: View {
    var title: String = "选择谁一起"
    var subtitle: String? = nil
    /// 预先勾上的。
    var initial: Set<UUID> = []
    var confirmTitle: String = "确定"
    var onDone: (Set<UUID>) -> Void

    @ObservedObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    quickAll
                    ForEach(store.contacts) { contact in
                        Button {
                            toggle(contact.id)
                        } label: {
                            row(contact)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(V2.gutter)
            }
            .background(V2.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onDone(picked)
                        dismiss()
                    }
                    .font(.aevis(15, weight: .semibold))
                }
            }
            .onAppear { picked = initial }
        }
    }

    private var allPicked: Bool {
        !store.contacts.isEmpty && picked.count == store.contacts.count
    }

    private var quickAll: some View {
        Button {
            picked = allPicked ? [] : Set(store.contacts.map(\.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: allPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(allPicked ? V2.accent : V2.dim(0.3))
                Text(allPicked ? "全部取消" : "全选（所有人一起）")
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text("\(picked.count)/\(store.contacts.count)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(V2.card, in: RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                    .stroke(V2.stroke, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.contacts.isEmpty)
    }

    private func toggle(_ id: UUID) {
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func row(_ contact: Contact) -> some View {
        let on = picked.contains(contact.id)
        return HStack(spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(on ? V2.accent : V2.dim(0.3))

            Circle()
                .fill(V2.soft(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(contact.displayName.prefix(1)))
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(V2.accent)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                if !contact.persona.relationship.isEmpty {
                    Text(contact.persona.relationship)
                        .font(.aevis(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(V2.card, in: RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                .stroke(on ? V2.accent.opacity(0.35) : V2.stroke, lineWidth: on ? 1 : 0.5)
        )
    }
}
