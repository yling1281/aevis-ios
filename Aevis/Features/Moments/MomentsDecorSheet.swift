import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「装扮朋友圈」—— 换封面 + 写一句签名。
///
/// ## 用户要的
/// 「每个人都能装扮自己的朋友圈」。
///
/// ⚠️ **现状说明**：朋友圈目前**是共享的一份**（不按联系人分开存），
/// 所以装扮也是整页那一套。要做成"每个人一套"，得先把朋友圈改成按联系人分库 ——
/// 那是数据结构层面的改动，不是加个界面就行。界面上那句说明照实写。
struct MomentsDecorSheet: View {

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var pickedCover: PhotosPickerItem?
    @State private var signature = ""
    @State private var note: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $pickedCover, matching: .images) {
                            Text("选一张封面")
                                .font(.aevis(14, weight: .medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 9)
                                .aevisGlass(cornerRadius: 14)
                        }
                        // PhotosPicker 的文字会被系统刷成强调色，要显式压回来
                        .tint(Color.primary)

                        if settings.momentCoverData != nil {
                            Button("去掉封面") {
                                settings.momentCoverData = nil
                                note = "封面去掉了。"
                            }
                            .font(.aevis(14))
                            .foregroundStyle(.red)
                            .buttonStyle(.borderless)
                        }

                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("封面上的那句话")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                        TextField("比如：今天也想你", text: $signature)
                            .font(.aevis(14.5))
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        Button("保存这句话") {
                            settings.momentSignature = signature.trimmingCharacters(in: .whitespacesAndNewlines)
                            note = settings.momentSignature.isEmpty ? "清空了，封面不再显示字。" : "记下了。"
                        }
                        .font(.aevis(14))
                        .foregroundStyle(settings.accentColor)
                        .buttonStyle(.borderless)
                    }

                    if let note {
                        Text(note)
                            .font(.aevis(12))
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("现在朋友圈是一份共享的，所以装扮也是整页那一套"
                         + "（换一次，所有联系人看到的一样）。\n"
                         + "封面图会压缩后只存在这台手机上，不会上传。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("装扮朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { signature = settings.momentSignature }
            .onChange(of: pickedCover) { _, item in
                guard let item else { return }
                loadCover(item)
            }
        }
    }

    // MARK: - 预览

    @ViewBuilder
    private var preview: some View {
        if let data = settings.momentCoverData, let image = UIImage(data: data) {
            Color.clear
                .frame(height: 150)
                // ⚠️ `image` 是 UIImage，**没有 `.resizable()`** ——
                // 必须先包成 `Image(uiImage:)`（build-53 就挂在这一句上）。
                .overlay(Image(uiImage: image).resizable().scaledToFill())
                // ⚠️ overlay **不裁剪**，不补这句图片会溢出整块卡片
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if !settings.momentSignature.isEmpty {
                        Text(settings.momentSignature)
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.bottom, 11)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(height: 110)
                .overlay(
                    Text("还没选封面")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - 动作

    private func loadCover(_ item: PhotosPickerItem) {
        note = nil
        Task { @MainActor in
            defer { pickedCover = nil }
            guard let raw = try? await item.loadTransferable(type: Data.self) else {
                note = "这张图读不出来，换一张试试。"
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: raw),
                  let compressed = AttachmentService.compressed(image, maxSide: 1600, quality: 0.85)
            else {
                note = "这张图格式不支持，换成 JPG 或 PNG 再试。"
                return
            }
            settings.momentCoverData = compressed
            note = "封面换好了。"
            #else
            note = "这个平台上换不了封面。"
            #endif
        }
    }
}
