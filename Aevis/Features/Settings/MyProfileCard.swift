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
    /// 登录状态 + 账号上的那份资料（用来做"同步到账号"）。
    @ObservedObject private var account = AccountService.shared

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var note: String?
    @State private var busyPush = false

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

                // ⚠️ **名字和头像要跟账号走**（用户 2026-09-28：
                //    「我说的账号名称是这里……我的资料那里是绑定的账号」）。
                //    登录之后这里改的是**账号上的名字** —— 换手机登同一个账号，
                //    名字头像照样在。没登录就只改本地这份。
                accountRow

                // 个性签名（用户 2026-09-28 要的）。
                // 就是"我在 TA 朋友圈里"名字下面那句。
                VStack(alignment: .leading, spacing: 7) {
                    Text("个性签名")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    TextField("比如：今天也想你", text: $profile.signature)
                        .font(.aevis(14))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                }

                Text(account.isSignedIn
                     ? "名字和头像跟着账号走 —— 换台手机登同一个账号，这边还是你。"
                     : "现在还没登录，改的只是这台手机上的记录。登录之后会同步到账号。")
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

    // MARK: - 账号那一行

    @ViewBuilder
    private var accountRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if account.isSignedIn {
                HStack(spacing: 8) {
                    Text("账号")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(account.profile?.displayName ?? "已登录")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)

                    Button {
                        pushNickname()
                    } label: {
                        Text(busyPush ? "同步中…" : "同步到账号")
                            .font(.aevis(13, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .aevisGlass(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(busyPush || !nicknameChanged)
                    .opacity(nicknameChanged ? 1 : 0.45)
                }
            } else {
                Text("还没登录账号。登录之后名字和头像会跟着账号走。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 本地名字和账号上的对不上 → 那个按钮才有意义。
    private var nicknameChanged: Bool {
        let mine = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let theirs = (account.profile?.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return mine != theirs
    }

    // MARK: - 动作

    private func pushNickname() {
        guard !busyPush else { return }
        busyPush = true
        let want = profile.nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { busyPush = false }
            do {
                let fresh = try await account.pushNickname(want)
                // 服务端会自己清掉换行/控制字符，回包才是"真正存下来的那个"
                profile.nickname = fresh.nickname
                note = "已经同步到账号了。"
            } catch {
                note = "没同步上去：\(error.localizedDescription)"
            }
        }
    }

    private func loadAvatar(_ item: PhotosPickerItem) {
        note = nil
        Task { @MainActor in
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                note = "这张图读不出来，换一张试试。"
                pickedAvatar = nil
                return
            }
            // 本地先换上（断网也不耽误看），再往账号上推
            profile.setAvatar(image)
            pickedAvatar = nil

            guard account.isSignedIn else {
                note = "头像换好了。"
                return
            }
            do {
                _ = try await account.uploadAvatar(image)
                note = "头像换好了，账号上也更新了。"
            } catch {
                note = "本机已经换了，但账号上没传上去：\(error.localizedDescription)"
            }
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
