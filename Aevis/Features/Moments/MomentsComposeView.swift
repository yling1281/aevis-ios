// 发布朋友圈（全屏二级页，2026-11-12）
//
// 用户：「朋友圈要做一个单独的口，就是右边上面三个点，你要再加一个发布朋友圈，
//       然后做一个全屏的二级菜单，在那里面做一个发布的 UI，然后在那里面去发布」。
//
// 同时按「每个东西都是要选的」加了两个可选项：
//   · 谁可以看：公开 / 仅自己
//   · 谁一起发：可以勾一个或多个人 —— 发出去时**每个人各发一条**（用户原话：
//     「发朋友圈的话是所有的人一起同时发朋友圈」）
import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct MomentsComposeView: View {
    /// (文字, 配图, 可见范围, 一起发的人)
    var onPost: (String, UIImage?, String?, Set<UUID>) -> Void

    @ObservedObject private var store = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var image: UIImage?
    /// nil / "public" = 公开；"private" = 仅自己
    @State private var audience: String = "public"
    @State private var togetherIDs: Set<UUID> = []
    @State private var showPicker = false
    @FocusState private var focused: Bool

    private var canPost: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editor
                Divider().opacity(0.4)
                options
                Spacer(minLength: 0)
            }
            .background(V2.background.ignoresSafeArea())
            .navigationTitle("发表朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发表") { submit() }
                        .font(.aevis(15, weight: .semibold))
                        .disabled(!canPost)
                }
            }
            .sheet(isPresented: $showPicker) {
                PersonaMultiPicker(
                    title: "谁一起发",
                    initial: togetherIDs,
                    confirmTitle: "确定"
                ) { ids in
                    togetherIDs = ids
                }
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    // MARK: - 编辑区

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("这一刻的想法…")
                        .font(.aevis(15))
                        .foregroundStyle(V2.dim(0.35))
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.aevis(15))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .focused($focused)
            }

            if let image {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 96, height: 96)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        self.image = nil
                        self.pickedPhoto = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }

            HStack(spacing: 18) {
                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("图片", systemImage: "photo")
                        .font(.aevis(14))
                        .foregroundStyle(V2.accent)
                }
                Spacer(minLength: 0)
                Text("\(text.count)")
                    .font(.aevis(11.5))
                    .foregroundStyle(V2.dim(0.35))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, V2.gutter)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    // MARK: - 选项

    private var options: some View {
        VStack(spacing: 0) {
            // 谁可以看
            HStack {
                Text("谁可以看")
                    .font(.aevis(14))
                Spacer(minLength: 8)
                Picker("", selection: $audience) {
                    Text("公开").tag("public")
                    Text("仅自己").tag("private")
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 14)

            Divider().opacity(0.35).padding(.leading, V2.gutter)

            // 谁一起发
            Button {
                showPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text("谁一起发")
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(togetherLabel)
                        .font(.aevis(13))
                        .foregroundStyle(togetherIDs.isEmpty ? V2.dim(0.4) : V2.accent)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(V2.dim(0.28))
                }
                .padding(.horizontal, V2.gutter)
                .padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.contacts.isEmpty)

            if !togetherIDs.isEmpty {
                Text("发出去时，他们各自会有一条相同内容的朋友圈")
                    .font(.aevis(11))
                    .foregroundStyle(V2.dim(0.4))
                    .padding(.horizontal, V2.gutter)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var togetherLabel: String {
        if togetherIDs.isEmpty { return "不发给他们" }
        if togetherIDs.count == store.contacts.count { return "所有人" }
        let names = store.contacts
            .filter { togetherIDs.contains($0.id) }
            .map(\.displayName)
            .prefix(2)
        let base = names.joined(separator: "、")
        return togetherIDs.count > 2 ? "\(base) 等 \(togetherIDs.count) 人" : base
    }

    // MARK: - 动作

    private func load(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else { return }
        await MainActor.run { image = img }
    }

    private func submit() {
        guard canPost else { return }
        onPost(text.trimmingCharacters(in: .whitespacesAndNewlines),
               image,
               audience == "private" ? "private" : nil,
               togetherIDs)
        dismiss()
    }
}
