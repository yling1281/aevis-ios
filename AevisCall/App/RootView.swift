import AVFoundation
import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「Aevis 通话」的界面。
///
/// 按设计稿第 5 节：这个包**尽量隐形**，平时只当后厨 —— 用户正常根本看不到它，
/// 看到的只有系统那张通话卡。这一页是「万一被点到」的兜底页，同时给老板一个
/// 看结果的入口：
///
/// - **一进 App 就自动试拨一次**，让老板装上就能立刻看到灵动岛弹不弹；
/// - 界面上再留一个大按钮「再试一次」；
/// - 一个头像 / 名字区（老板要的可自定义来电头像与名字）；
/// - 底部一行小字点明「第一次装完要手动打开一次给麦克风权限」。
///
/// ## 视觉铁律
/// 纯白或纯黑底（用 `systemBackground`，深浅色各是纯白 / 纯黑），
/// 无渐变、无背景图；卡片用材质（Material）做玻璃质感。
struct RootView: View {
    @EnvironmentObject private var shell: CallShell
    @EnvironmentObject private var identity: CallIdentityStore

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var avatarNote: String?

    var body: some View {
        ZStack {
            // 纯白 / 纯黑底。跟这个项目的视觉铁律一致：无渐变、无背景图。
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBlock
                    tryButton
                    identityBlock
                    logBlock
                    footnote
                }
                .padding(20)
            }
        }
        .task {
            // 一进来就先要一次麦克风权限。
            // ⚠️ iOS 不给「从没打开过」的 App 权限 —— 第一次装完必须手动打开一次，
            //    这一步躲不掉，兜底页底部的说明和装机说明里都写清了。
            await requestMicrophone()
            // 自动试拨一次 —— 老板装上就能看灵动岛弹不弹，不用点按钮。
            shell.start(displayName: identity.displayName, iconTemplateData: identity.iconTemplateData)
        }
        .onChange(of: pickedAvatar) { _, item in
            guard let item else { return }
            loadAvatar(item)
        }
    }

    // MARK: - 顶部状态

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle()
                    .frame(width: 9, height: 9)
                    .foregroundStyle(CallShell.isSupported ? Color.green : Color.red)
                Text(statusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(statusDetail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTitle: String {
        CallShell.isSupported ? "LiveCommunicationKit 可用" : "LiveCommunicationKit 不可用"
    }

    private var statusDetail: String {
        if !CallShell.isSupported {
            return CallShell.unsupportedReason
        }
        switch shell.phase {
        case .idle:
            return "点下面的大按钮，会弹一次苹果的系统通话界面，几秒后自动挂断。"
        case .starting:
            return "正在拨，等系统回话（最多 6 秒）…"
        case .ringing:
            return "系统界面弹出来了 —— 这条路通。"
        case .failed:
            return shell.lastFailure ?? "系统没给界面。"
        case .ended:
            return "已挂断。想再看一次就点「再试一次」。"
        }
    }

    // MARK: - 大按钮

    private var tryButton: some View {
        Button {
            shell.start(displayName: identity.displayName, iconTemplateData: identity.iconTemplateData)
        } label: {
            Text("试一下（弹苹果通话界面）")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .disabled(shell.phase == .starting)
    }

    // MARK: - 头像与名字

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来电图标与名字")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                avatarPreview

                VStack(alignment: .leading, spacing: 10) {
                    PhotosPicker(selection: $pickedAvatar, matching: .images) {
                        Text("从相册选一张")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    // PhotosPicker 的文字会被系统刷成强调色，要显式压回来。
                    .tint(Color.primary)

                    if identity.hasAvatar {
                        Button {
                            identity.clearAvatar()
                            avatarNote = "图标已清掉，用系统默认的。"
                        } label: {
                            Text("清掉图标")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }

            TextField("对方显示的名字（默认 ta）", text: nameBinding)
                .font(.system(size: 15))
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let note = avatarNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // 如实说：系统卡上的图标是单色剪影，不是彩色照片。
            Text("说明：系统那张卡上的小图标是模板渲染（单色剪影），不会显示彩色照片。名字会原样显示在系统界面上。")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { identity.displayName },
            set: { identity.setDisplayName($0) }
        )
    }

    private var avatarPreview: some View {
        Group {
            if let image = identity.avatarImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
        .frame(width: 64, height: 64)
        .background(Color.primary.opacity(0.06), in: Circle())
        .clipShape(Circle())
    }

    // MARK: - 明细

    private var logBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("明细（排错用）")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    shell.copyAll()
                } label: {
                    Text(shell.justCopied ? "已复制" : "复制")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(shell.lines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 150)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - 底注

    private var footnote: some View {
        Text("第一次装完请务必打开本 App 一次并允许麦克风，否则打不通 —— iOS 不会给一个从没被打开过的 App 麦克风权限。")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 动作

    private func requestMicrophone() async {
        #if canImport(AVFoundation)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    private func loadAvatar(_ item: PhotosPickerItem) {
        avatarNote = nil
        Task { @MainActor in
            #if canImport(UIKit)
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                avatarNote = "这张图读不出来，换一张试试。"
                pickedAvatar = nil
                return
            }
            if let image = UIImage(data: data) {
                identity.setAvatar(image)
                avatarNote = "图标换好了（系统卡上是单色剪影）。"
            } else {
                avatarNote = "这张图格式不支持，换一张试试。"
            }
            #endif
            pickedAvatar = nil
        }
    }
}
