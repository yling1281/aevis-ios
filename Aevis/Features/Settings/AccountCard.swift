import SwiftUI

/// 「账号」设置卡。
///
/// 用户说「到时候会拿新的服务器跟你对接」—— 所以这一页现在只做两件事：
/// **填服务器地址**、**注册 / 登录**。
/// 地址留空就整块是「未连接」，App 别的功能一样都不少（这是本地 App）。
///
/// 密码**不落盘**：填完当场用掉，成功只留 token（进钥匙串）。
///
/// ⚠️ 2026-09-29：这一页**不再承担任何登录动作**。
///    2026-09-28 起登录整体搬进了 App（`LoginView`：验证码 / 密码 / 注册码 / QQ），
///    而且是**强制登录** —— 没登录时进不了主界面。
///    所以这张卡实际只在「已登录」状态下看得到，能做的只有：
///    **看状态 / 刷新资料 / 退出 / 换线**。
///    （以前这里有一套"开系统浏览器去官网登录"的死代码 + 一个永远打不开的
///     密码表单 sheet，2026-09-29 清掉了：`startWebLogin`、`formSheet`、
///     以及配合它的 `webLoginURL()`。留着只会让人以为还能从这儿登。）
struct AccountCard: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var account = AccountService.shared

    @State private var note: String?
    @State private var busy = false
    @State private var probing = false
    @State private var switching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("账号")

            serverRow
            rule
            statusRow
            if account.isSignedIn {
                rule
                profileRow
            }
            rule
            actionRow

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            if let error = account.lastError, !error.isEmpty {
                rule
                Text(error)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            rule
            Text("服务器地址已经内嵌在 App 里，不用你填。这个账号是可选的："
                 + "人设、聊天记录、记忆本来都只存在这台手机上。\n"
                 + "账号用来同步昵称和头像（在网页的「我的账号」里改，这里点「刷新资料」同步）。"
                 + "密码只在登录页那一下用，不会被存下来。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 各行

    private var serverRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            row {
                VStack(alignment: .leading, spacing: 3) {
                    Text("服务器")
                        .font(.aevis(15))
                    Text(lineText)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(probing ? "探测中…" : "自动") {
                    Task { await reprobe() }
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(probing || switching)
            }
            linePicker
        }
    }

    /// 三条线路的**手动点选**排 —— 老板要的「三个路线你自己点选」。
    ///
    /// 当前那条高亮；点别的先探（`AccountEndpoint.use(_:)` 探通才切），探不通就不动。
    /// ⚠️ 只显示**线路名**（线路一 / 线路二 / 线路三），不显示主机名、更不显示接口随机前缀
    ///    —— 用户会把设置页截图发群里。主机名在上面 `lineText` 那一行里。
    private var linePicker: some View {
        HStack(spacing: 8) {
            ForEach(AevisHosts.accountLines) { line in
                lineButton(line)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 13)
    }

    /// 一个可点选的线路按钮。当前这条用强调色填充，其余是淡灰胶囊底。
    private func lineButton(_ line: AevisHosts.Line) -> some View {
        let active = AevisHosts.lineName(for: settings.accountServerURL) == line.name
        return Button {
            Task { await switchTo(line) }
        } label: {
            Text(line.name)
                .font(.aevis(13, weight: active ? .medium : .regular))
                .foregroundStyle(active ? Color.white : Color.secondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(active ? settings.accentColor : Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
        .disabled(switching || probing)
        .opacity(switching && !active ? 0.5 : 1)
    }

    /// 用户点了某条线路 —— 先探，通了才切。
    ///
    /// ⭐ 复用 `AccountEndpoint.use(_:)`：它自己会探 `/api/health`，
    ///    探通才写缓存并返回 true；探不通返回 false，界面保持原样、只给个提示。
    private func switchTo(_ line: AevisHosts.Line) async {
        switching = true
        defer { switching = false }
        if await AccountEndpoint.use(line.base) {
            settings.accountServerURL = line.base
            note = "已切到\(line.name)。"
        } else {
            note = "\(line.name)连不上，换一条试试。"
        }
    }

    /// 「线路一 · account.aevis.cn」—— 让用户看得出现在走的是哪条线。
    /// 域名会被云厂商按**线路抽样**拦，所以三条线互为备用；既能在启动时自动切换，
    /// 也能在上面那排按钮里手动点选。
    ///
    /// ⚠️ 只显示**主机名**，不显示路径 —— 接口那段随机前缀不该出现在截图里
    ///    （用户会把设置页截图发群里）。
    private var lineText: String {
        let host = URL(string: settings.accountServerURL)?.host ?? ""
        if host.isEmpty { return "没配" }
        guard let line = AevisHosts.lineName(for: settings.accountServerURL) else {
            return host
        }
        return line + " · " + host
    }

    /// 手动重新探测线路（启动时已经自动探过一次，这里给用户一个"我手动试一下"的入口）。
    private func reprobe() async {
        probing = true
        defer { probing = false }
        let base = await AccountEndpoint.refresh()
        settings.accountServerURL = base
        if let line = AevisHosts.lineName(for: base) {
            note = "已切到\(line)。"
        } else {
            note = "三条线路都连不上，稍后再试。"
        }
    }

    private var statusRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("状态")
                    .font(.aevis(15))
                Text(account.statusLine)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if account.isSignedIn {
                Button("刷新资料") {
                    Task {
                        busy = true
                        await account.refreshProfile()
                        busy = false
                    }
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .disabled(busy)
            }
        }
    }

    /// 已登录时显示的**账号资料**：头像 + 昵称 + 账号号。
    ///
    /// 这三样都**跟着账号走**：在网页的「我的账号」里改了昵称或头像，
    /// 这里点一下「刷新资料」就同步过来（换手机登录也是同一份）。
    /// 没设过头像就回落成昵称首字，不会留一块空白。
    private var profileRow: some View {
        row {
            avatarView
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.profile?.displayName ?? "已登录")
                    .font(.aevis(15, weight: .medium))
                    .lineLimit(1)
                Text(handleText)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("改昵称 / 换头像在网页「我的账号」里")
                    .font(.aevis(10.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
        }
    }

    /// 「账号号 12345678 · xxx@qq.com」—— 两个都有就都显示，只有一个就显示那一个。
    private var handleText: String {
        guard let profile = account.profile else { return "资料还没拉到，点「刷新资料」" }
        var parts: [String] = []
        if !profile.accountNo.isEmpty { parts.append("账号号 " + profile.accountNo) }
        if !profile.username.isEmpty { parts.append(profile.username) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// 头像。有图就加载，没有（或加载失败）回落成首字圆点。
    ///
    /// ⚠️ `AsyncImage` 失败时**什么都不画**（留一块空的），所以必须给 fallback ——
    ///    否则网络一差，那一行就变成"名字旁边一个洞"。
    @ViewBuilder
    private var avatarView: some View {
        if let url = account.avatarURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    avatarFallback
                }
            }
            .clipShape(Circle())
        } else {
            avatarFallback
        }
    }

    private var avatarFallback: some View {
        Text(account.profile?.initial ?? "A")
            .font(.aevis(18, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Circle().fill(Color.accentColor.opacity(0.8)))
    }

    private var actionRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text(account.isSignedIn ? "退出登录" : "登录")
                    .font(.aevis(15))
                Text(account.isSignedIn
                     ? "退出之后会回到登录页，重新登录就能进来"
                     : "在登录页登 —— 验证码 / 密码 / QQ 都能用")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if account.isSignedIn {
                Button("退出") {
                    account.signOut()
                    note = "已退出，回到登录页了。"
                }
                .font(.aevis(14))
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
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

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
