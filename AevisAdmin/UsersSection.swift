import SwiftUI
import UIKit

/// 账号列表。
///
/// ⚠️ 这里三个操作都会**不可逆地影响别人**，所以：
/// 删除要二次确认；封号/封设备只做标记（能解封）。
/// 管理员自己的账号不允许删（服务器那边也拦着，这里只是别让人白点）。
struct UsersSection: View {
    @EnvironmentObject private var store: AdminStore

    @State private var keyword = ""
    @State private var pendingDelete: AdminUser?

    private var shown: [AdminUser] {
        let key = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return store.users }
        return store.users.filter { user in
            (user.email ?? "").lowercased().contains(key)
                || (user.deviceId ?? "").lowercased().contains(key)
                || (user.lastIp ?? "").contains(key)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            searchField

            AdminSectionTitle(text: "已注册的账号（\(store.users.count)）")

            if store.users.isEmpty {
                AdminCard { AdminEmpty(text: store.loading ? "读取中…" : "还没有人注册。") }
            } else if shown.isEmpty {
                AdminCard { AdminEmpty(text: "没有匹配「\(keyword)」的账号。") }
            } else {
                AdminCard {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, user in
                        row(user, divider: index > 0)
                    }
                }
            }

            AdminNote(text: "「封号」会立刻清掉他的登录态（手机上那个登录马上失效）；"
                     + "「封设备」按设备码记，跟账号解耦 —— 他删号重注册、换个邮箱再来，"
                     + "只要还是这台机器就绑不上。管理员账号不能被删，防止把自己锁在外面。")
        }
        .alert("确认删除这个账号？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let email = pendingDelete?.email {
                    Task { await store.deleteUser(email) }
                }
                pendingDelete = nil
            }
            Button("算了", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("邮箱 \(pendingDelete?.email ?? "") 会被删掉，他手机上的登录会失效。"
                 + "这个操作不可逆 —— 聊天记录在他自己手机上，删账号不会删他的记录。")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            TextField("搜邮箱 / 设备码 / IP", text: $keyword)
                .font(.system(size: 14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ user: AdminUser, divider: Bool) -> some View {
        AdminCardRow(showsDivider: divider) {
            AdminLine(
                title: user.email ?? "—",
                subtitle: meta(user),
                detail: deviceLine(user),
                badge: badge(user)
            )
        } trailing: {
            VStack(spacing: 6) {
                AdminMiniButton(title: user.isBlocked ? "解封" : "封禁",
                                tint: user.isBlocked ? AdminSkin.brand : AdminSkin.danger) {
                    Task {
                        await store.blockUser(user.email ?? "", blocked: !user.isBlocked,
                                              reason: user.isBlocked ? "" : "后台手工封禁")
                    }
                }
                if let device = user.deviceId, !device.isEmpty {
                    AdminMiniButton(title: "封设备", tint: AdminSkin.danger) {
                        Task { await store.blockDevice(device, blocked: true) }
                    }
                    // ⚠️ 「解绑」和「解封」是**两件事**，两个都要有，缺一个都会让人卡住：
                    //    · 封设备 = 把他挡在门外（`blocked_devices`）
                    //    · 解绑   = 删掉"这台机器归谁"的登记（`devices`）——
                    //      他换手机 / 重装系统 / 刷机之后卡住，要用的就是这个
                    AdminMiniButton(title: "解绑设备", tint: AdminSkin.brand) {
                        Task { await store.unbindDevice(device) }
                    }
                }
                AdminMiniButton(title: "删除", tint: AdminSkin.danger) {
                    pendingDelete = user
                }
                .disabled((user.email ?? "").isEmpty)
            }
        }
    }

    private func meta(_ user: AdminUser) -> String {
        var parts: [String] = []
        parts.append("注册 \(AdminFormat.when(user.createdAt))")
        if let last = user.lastLogin, last > 0 {
            parts.append("最后登录 \(AdminFormat.ago(last))")
        } else {
            parts.append("从没登录过")
        }
        if let count = user.loginCount, count > 0 { parts.append("登录 \(count) 次") }
        return parts.joined(separator: " · ")
    }

    private func deviceLine(_ user: AdminUser) -> String {
        var parts: [String] = []
        if let device = user.deviceId, !device.isEmpty {
            parts.append("设备 \(device)")
        } else {
            parts.append("设备 未绑定")
        }
        if let ip = user.lastIp, !ip.isEmpty { parts.append("IP \(ip)") }
        if let ua = user.lastUa, !ua.isEmpty { parts.append(shortUA(ua)) }
        return parts.joined(separator: "　")
    }

    private func badge(_ user: AdminUser) -> (String, Color)? {
        if user.isBlocked { return ("已封", AdminSkin.danger) }
        if store.admins.contains(where: { $0.lowercased() == (user.email ?? "").lowercased() }) {
            return ("管理员", AdminSkin.brand)
        }
        return nil
    }

    /// 把一长串 User-Agent 压成「iPhone · Safari」这种能看的样子。
    private func shortUA(_ ua: String) -> String {
        var out: [String] = []
        if ua.contains("iPhone") { out.append("iPhone") }
        else if ua.contains("iPad") { out.append("iPad") }
        else if ua.contains("Android") { out.append("Android") }
        else if ua.contains("Macintosh") { out.append("Mac") }
        else if ua.contains("Windows") { out.append("Windows") }
        else { out.append("浏览器") }
        if ua.contains("aevis") { out.append("Aevis") }
        else if ua.contains("MicroMessenger") { out.append("微信内") }
        else if ua.contains("Edg/") { out.append("Edge") }
        else if ua.contains("Chrome/") { out.append("Chrome") }
        else if ua.contains("Firefox/") { out.append("Firefox") }
        else if ua.contains("Safari") { out.append("Safari") }
        return out.joined(separator: " · ")
    }
}
