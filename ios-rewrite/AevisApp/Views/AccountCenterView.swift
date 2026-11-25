import SwiftUI
import PhotosUI
import UIKit

/// 账号中心（2026-11-22 新增，照「忆伴」账号中心参考图做）。
///
/// 用户要求「目前没有的功能先不加按钮」——这里只放真实可用的内容：
/// - 顶部卡：头像 + 昵称 + 「账号 xxx」+ 会员/普通徽章（全部来自 `/v1/me`）
/// - 系统 · 关于：只读展示版本号（Bundle 读，不需要二级页面）
/// - 底部红色「退出登录」
/// 参考图里的「个人信息 / 个人资料 / 我的猫粮 / 各类配置 / 服务器」页面都还没实现，
/// 一律不出现（也不做灰按钮和「即将上线」占位）。
///
/// 数据：`/v1/me`（昵称 / 头像 / 脱敏邮箱 / membership.days_left）。
/// 取不到一律显示占位（「Aevis 用户」「—」），不空着。
///
/// 入口：`SettingsView` 顶部品牌卡点击（sheet 呈现，自带「完成」关闭）。
struct AccountCenterView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    /// `/v1/me` 解析结果（字段见 build_user/aevis_auth.py store.me）。
    private struct MeInfo {
        var uid = ""
        var nickname = ""
        var avatar = ""
        var email = ""          // 服务端已脱敏（a***@qq.com）
        var memberActive = false
        var memberDays = 0
    }

    @State private var info = MeInfo()
    /// `/v1/me` 失败时给一行明确提示（占位仍在），可下拉重试；不再静默空白。
    @State private var loadFailed = false

    /// 换头像（2026-11-25）：相册选图 → `/v1/media` 上传拿路径 → `POST /v1/me/profile` 写回。
    /// 注意只动「登录用户头像」，**不碰人设广场**（那是 persona.avatar，另一套数据）。
    @State private var pickerItem: PhotosPickerItem?
    @State private var uploadingAvatar = false
    @State private var avatarError = ""
    @State private var showAvatarError = false

    private let dangerRed = Color.hex(0xE5484D)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    headerCard

                    if loadFailed {
                        Text("账号信息暂时取不到，下拉可重试")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AE.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 可点的账号/头像设置（目前只有换头像；「目前没有的功能先不加按钮」）
                    groupBlock("账号") {
                        avatarRow
                    }

                    groupBlock("系统") {
                        aboutRow
                    }

                    signOutButton
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .background(Color.clear)
            .navigationTitle("账号中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .alert("头像换不了", isPresented: $showAvatarError) {
                Button("好", role: .cancel) { }
            } message: {
                Text(avatarError)
            }
        }
        .tint(AE.accent)
    }

    // MARK: - 顶部大卡

    private var headerCard: some View {
        HStack(spacing: 14) {
            avatarView
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(displayName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                        .lineLimit(1)
                    badge
                }
                Text("账号 \(accountText)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: AE.cardRadius + 2, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 10, y: 4)
    }

    /// 头像：硬缓存（磁盘 + 条件请求 304），AsyncImage 会每次重新下载且断网就没了。
    private var avatarView: some View {
        Group {
            if let url = avatarURL {
                CachedRemoteImage(url: url) {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
        )
    }

    private var avatarPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [AE.accentLift, AE.accentDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(initialChar)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private var badge: some View {
        HStack(spacing: 3.5) {
            Image(systemName: info.memberActive ? "crown.fill" : "person.fill")
                .font(.system(size: 8.5, weight: .bold))
            Text(badgeText)
                .font(.system(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(AE.accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(AE.accentSoft, in: Capsule())
    }

    /// 徽章：会员（带剩余天数）/ 普通用户。
    private var badgeText: String {
        guard info.memberActive else { return "普通用户" }
        return info.memberDays > 0 ? "会员 · \(info.memberDays) 天" : "会员"
    }

    /// 「更换头像」行：整行是 PhotosPicker 的触发区，右侧带上传进度。
    /// 上传走 `/v1/media`（与安卓同接口同字段），成功后写 `POST /v1/me/profile`。
    private var avatarRow: some View {
        PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 24, alignment: .center)
                Text("更换头像")
                    .font(.system(size: 15.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                if uploadingAvatar {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AE.textSecondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(uploadingAvatar)
        // 选完图立刻上传，不需要再点一次保存
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await uploadAvatar(item) }
        }
    }

    /// 头像上传：读 Data → 缩到长边 512 → JPEG → `/v1/media` → `/v1/me/profile`。
    /// 缩到 512 是因为头像最大只显示 62pt（@3x ≈ 186px），传原图十几 MB 纯浪费流量。
    @MainActor
    private func uploadAvatar(_ item: PhotosPickerItem) async {
        guard let token = session.token, !token.isEmpty else {
            avatarError = "登录状态已失效，请重新登录"
            showAvatarError = true
            pickerItem = nil
            return
        }
        uploadingAvatar = true
        defer { uploadingAvatar = false; pickerItem = nil }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let raw = UIImage(data: data) else {
                throw NSError(domain: "aevis.avatar", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "这张图片读不出来，换一张试试。"] )
            }
            let small = Self.downscaled(raw, maxSide: 512)
            guard let jpg = small.jpegData(compressionQuality: 0.85) else {
                throw NSError(domain: "aevis.avatar", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "图片压缩失败，换一张试试。"] )
            }
            let path = try await APIClient.uploadImage(
                token: token, data: jpg, filename: "avatar.jpg")
            _ = try await APIClient.updateProfile(token: token, avatar: path)
            // 立刻刷新本地：头部大图 + 首页问候区都读这份
            info.avatar = path
            session.applyAvatar(path)
        } catch {
            avatarError = error.localizedDescription
            showAvatarError = true
        }
    }

    /// 等比缩到长边 maxSide（小于就原样返回，不放大）。
    private static func downscaled(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let w = img.size.width
        let h = img.size.height
        guard w > 0, h > 0 else { return img }
        let scale = min(1, maxSide / max(w, h))
        guard scale < 1 else { return img }
        let size = CGSize(width: floor(w * scale), height: floor(h * scale))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true          // 头像没有透明需求，opaque 更小更快
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 分组（只读信息，不带可点感）

    @ViewBuilder
    private func groupBlock<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AE.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 0) { content() }
                .glassCard(cornerRadius: 20, material: .regular, tintOpacity: 0.18)
                .shadow(color: AE.shadowColor, radius: 8, y: 3)
        }
    }

    /// 关于：纯展示版本号，没有二级页面，所以不做成按钮、也不画箭头。
    private var aboutRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(width: 24, alignment: .center)
            Text("关于")
                .font(.system(size: 15.5))
                .foregroundStyle(AE.textPrimary)
            Spacer(minLength: 8)
            Text(versionText)
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    // MARK: - 退出登录

    private var signOutButton: some View {
        Button {
            session.signOut()
            dismiss()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                Text("退出登录")
                    .font(.system(size: 15.5, weight: .medium))
            }
            .foregroundStyle(dangerRed)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .glassCard(cornerRadius: 18, material: .regular, tintOpacity: 0.14)
        }
        .buttonStyle(AevisPressStyle(scale: 0.98))
    }

    // MARK: - 展示文案

    private var displayName: String {
        info.nickname.isEmpty ? "Aevis 用户" : info.nickname
    }

    private var initialChar: String {
        guard let c = displayName.first else { return "A" }
        return String(c)
    }

    /// 账号：优先服务端脱敏邮箱（隐私友好），其次本地登录邮箱，最后 uid。
    private var accountText: String {
        if !info.email.isEmpty { return info.email }
        if !session.email.isEmpty { return session.email }
        if !info.uid.isEmpty { return "ID \(info.uid)" }
        return "—"
    }

    /// 头像地址：服务端可能下发相对路径（`/static/...`），补成绝对地址。
    private var avatarURL: URL? {
        let path = info.avatar
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        if path.hasPrefix("/") { return URL(string: APIClient.base + path) }
        return URL(string: path)
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.2"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "5"
        return "\(v) (\(b))"
    }

    // MARK: - 加载

    private func load() async {
        guard let token = session.token, !token.isEmpty else {
            // 未登录：页面靠占位文案显示，不发 /v1/me
            await MainActor.run { loadFailed = false }
            return
        }
        guard let json = try? await APIClient.me(token: token) else {
            await MainActor.run { loadFailed = true }
            return
        }

        var m = MeInfo()
        if let n = json["uid"] as? NSNumber { m.uid = n.stringValue }
        else if let s = json["uid"] as? String { m.uid = s }
        m.nickname = (json["nickname"] as? String) ?? ""
        m.avatar = (json["avatar"] as? String) ?? ""
        m.email = (json["email"] as? String) ?? ""
        if let mm = json["membership"] as? [String: Any] {
            m.memberActive = (mm["active"] as? Bool) ?? false
            m.memberDays = (mm["days_left"] as? NSNumber)?.intValue ?? 0
        }
        await MainActor.run {
            info = m
            loadFailed = false
        }
    }
}
