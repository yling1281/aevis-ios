import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「我的资料」—— 我的头像、我的名字。
///
/// 和 TA 的设定**分开**：这是我的部分，改它不该动到她。
/// 用户原话：「我的话也能改头像、改名称、改气泡。」
struct MyProfileCard: View {
    @ObservedObject private var profile = ProfileStore.shared

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("我的资料")

            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 14) {
                    AevisAvatar(source: .me, size: 56)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $pickedAvatar, matching: .images) {
                                Text("换个头像")
                                    .font(.aevis(14, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 9)
                                    .aevisGlass(cornerRadius: 14)
                            }
                            // PhotosPicker 是控件，系统会把强调色刷到它的文字上。
                            .tint(Color.primary)

                            if profile.avatarImage != nil {
                                Button {
                                    profile.setAvatar(nil)
                                    note = "已删掉，退回默认的圆点。"
                                } label: {
                                    Text("删掉")
                                        .font(.aevis(14))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 15)
                                        .padding(.vertical, 9)
                                        .aevisGlass(cornerRadius: 14)
                                }
                            }

                            Spacer(minLength: 0)
                        }

                        if let note {
                            Text(note)
                                .font(.aevis(12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("我的名字")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    TextField("留空也行", text: $profile.nickname)
                        .font(.aevis(14))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }

                Text("这是你自己 —— 头像和名字只存在这台手机上。要说给 TA 听的名字，写在「TA 的设定 → TA 怎么叫你」里。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
        .onChange(of: pickedAvatar) { _, item in
            guard let item else { return }
            loadAvatar(item)
        }
    }

    // MARK: - 动作

    private func loadAvatar(_ item: PhotosPickerItem) {
        note = nil
        Task { @MainActor in
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                note = "这张图读不出来，换一张试试。"
                pickedAvatar = nil
                return
            }
            profile.setAvatar(image)
            note = "头像换好了。"
            pickedAvatar = nil
        }
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }
}
