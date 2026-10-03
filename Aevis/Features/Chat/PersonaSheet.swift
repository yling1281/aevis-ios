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

    @Environment(\.dismiss) private var dismiss

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var editing = false
    @State private var showClearConfirm = false
    /// #24（2026-09-30）：看 TA 的钱包改成从这里点进去。
    @State private var showTaWallet = false
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
            .sheet(isPresented: $showTaWallet) {
                TaWalletSheet()
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
            // ⚠️⚠️ **这一页只留「编辑资料」**（用户 2026-09-28 原话：
            //    「我说了好多遍了，就是右上角的话，就只有编辑资料」）。
            //
            // 以前这里还挂着两行：
            //   ·「聊天背景与外观」→ 其实开的是**整个设置页**（20 多张卡），
            //     他每次都要骂一次"说了多少遍不要全部设置"
            //   ·「TA 的朋友圈」→ 看朋友圈在「发现」那一页，这里不需要第二个入口
            // 两行都撤了。外观设置仍在「设置 → 外观」里，功能一个没少。
            row("编辑资料", "名字、性别、性格、说话方式、关系、音色") {
                editing = true
            }
            // #24（2026-09-30）：看 TA 的钱包从这儿点进去（钱包页里不再显示 TA 余额）。
            row("TA 的钱包", WalletStore.money(WalletStore.shared.taBalance)) {
                showTaWallet = true
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
            personaStore.setAvatar(image, original: data)
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

/// #24（2026-09-30）：从「TA 的资料」点进来的 TA 钱包（只读，假数据）。
struct TaWalletSheet: View {
    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "TA" : name
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(WalletStore.money(wallet.taBalance))
                    .font(.aevis(34, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(personaName)的钱包")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                Text("这也是本机上的假数据 —— 不接真钱，也不会真的从谁那里扣。")
                    .font(.aevis(12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer(minLength: 0)
            }
            .padding(.top, 54)
            .frame(maxWidth: .infinity)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("TA 的钱包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
