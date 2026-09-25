import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「TA 的资料」—— 聊天页右上角点进来的那一页。
///
/// ## 为什么要有它（用户原话）
/// 「打开这个人的右上角，为什么跟设置一样的？联系人右上角应该是给对方改头像、
/// 姓名、聊天人设、背景图之类的呀」
///
/// 以前那个位置是个**全局设置**按钮 —— 点开的是"整个 App 的设置"，
/// 跟你正在跟谁聊天一点关系都没有。现在这一页只放**和这个人有关**的东西。
struct PersonaSheet: View {

    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var router = AppRouter.shared

    @Environment(\.dismiss) private var dismiss

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var editing = false
    @State private var showClearConfirm = false
    @State private var note: String?

    private var persona: Persona { personaStore.persona }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    avatarCard
                    editCard
                    dangerCard

                    if let note {
                        Text(note)
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("TA 的资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $editing) {
                PersonaEditorView(isFirstRun: false)
            }
            .confirmationDialog("清空和 TA 的聊天记录？",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    chatClear()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删聊天记录，人设、记忆、头像都留着。删了找不回来 —— 先导一份备份更稳妥。")
            }
            .onChange(of: pickedAvatar) { _, item in
                guard let item else { return }
                loadAvatar(item)
            }
        }
    }

    // MARK: - 头像与名字

    private var avatarCard: some View {
        VStack(spacing: 12) {
            AevisAvatar(size: 84, seed: persona.avatarSeed)

            VStack(spacing: 3) {
                Text(persona.name.isEmpty ? "还没起名字" : persona.name)
                    .font(.aevis(19, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("性别：" + persona.gender.label + "　·　该怎么称呼由它决定")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedAvatar, matching: .images) {
                    Text("换头像")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                // PhotosPicker 的文字会被系统刷成强调色，要显式压回来
                .tint(Color.primary)

                if personaStore.avatarImage != nil {
                    Button {
                        personaStore.setAvatar(nil)
                        note = "自定义头像删掉了，换回自动生成的那个。"
                    } label: {
                        Text("删掉头像")
                            .font(.aevis(14))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 能改的东西

    private var editCard: some View {
        VStack(spacing: 0) {
            row("编辑资料", "名字、性别、性格、说话方式、关系、音色") {
                editing = true
            }
            rule
            row("聊天背景与外观", "玻璃、背景图、主题色、字体") {
                // ⚠️ 背景目前是**全局**的（改一次所有联系人跟着变）。
                // 所以这里如实说是"外观设置"，不假装是"只改这个人"。
                open { router.showSettings = true }
            }
            rule
            row("TA 的朋友圈", "TA 发过的动态和装扮") {
                open { router.showMoments = true }
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private var dangerCard: some View {
        VStack(spacing: 0) {
            Button {
                showClearConfirm = true
            } label: {
                HStack {
                    Text("清空和 TA 的聊天记录")
                        .font(.aevis(15))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 动作

    /// 先关掉这一页、再开别处。
    ///
    /// ⚠️ **两个 sheet 同时 present 会被系统吞掉**（表现就是"点了没反应"），
    /// 所以中间让出一拍再开。
    private func open(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { action() }
    }

    private func chatClear() {
        ChatStore.shared.clear()
        note = "聊天记录清空了，人设和记忆都留着。"
    }

    private func loadAvatar(_ item: PhotosPickerItem) {
        note = nil
        Task { @MainActor in
            defer { pickedAvatar = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                note = "这张图读不出来，换一张试试。"
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                note = "这张图格式不支持，换成 JPG 或 PNG 再试。"
                return
            }
            personaStore.setAvatar(image)
            note = "头像换好了。"
            #else
            note = "这个平台上换不了头像。"
            #endif
        }
    }

    // MARK: - 零件

    private func row(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
