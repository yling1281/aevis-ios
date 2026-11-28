import SwiftUI

/// 设置 /「我的」（2026-11-22 视觉重做，照用户给的「忆伴」设置页参考图）。
///
/// 只放**真实生效**的功能（用户要求：没实现的先不要放按钮）：
/// - 顶部用户卡片（头像 + 昵称 + 账号/会员状态，点击进账号中心）
/// - 外观：跟随系统 / 浅色 / 深色 —— 写 `themeMode`，由 `AevisApp` 根视图统一读取生效
/// - 配置：服务器状态（真实探测四条线路 + `/v1/models/status`）、主题配置（背景图/位置/模糊）
/// - 消息大小：小 / 标准 / 大（`msgSize`，ChatView 里 `AE.chatFont(msgSize)` 在用）
/// - 数据：云端同步状态 + 手动「从云端恢复聊天记录」（`CloudBackup.restoreNow`）
/// - 退出登录
///
/// 存储键保持不变：themeMode / msgSize / aevisBgStyle / aevisBgBlur / aevisBgImagePath。
/// 页面铺 `AppBackground()`，卡片统一磨砂玻璃 + 20 圆角，层次靠材质和留白，不靠重边框。
struct SettingsView: View {
    @EnvironmentObject private var session: Session

    /// 云端备份状态（`CloudBackup.shared` 的 lastSyncText / restoreNow 都是真实实现）
    @ObservedObject private var backup = CloudBackup.shared

    @AppStorage("themeMode") private var themeMode = 0   // 0 跟随系统 / 1 浅色 / 2 深色
    @AppStorage("msgSize") private var msgSize = 1

    /// 背景（第 3 轮）：预设索引与 AppBackground.Preset 的 rawValue 对齐。
    /// 详细调节都移到「主题配置」页，这里只读出来显示当前用的是哪套。
    @AppStorage("aevisBgStyle") private var bgStyle = 0
    @AppStorage("aevisBgImagePath") private var bgImagePath = ""

    /// 账号中心：点顶部用户卡片打开（sheet）。
    @State private var showAccount = false

    /// 手动云端恢复的进行中 / 结果提示。
    @State private var restoring = false
    @State private var restoreMessage = ""
    @State private var showRestoreAlert = false

    /// 顶部用户卡片：昵称 / 会员状态来自 `/v1/me`（Session 上只有 avatar，没有昵称）。
    @State private var nickname = ""
    @State private var memberActive = false
    @State private var memberDays = 0
    @State private var profileLoaded = false

    /// 4 个背景预设的名字（顺序 / rawValue 必须与 AppBackground.Preset 一致）。
    private let bgNames = ["奶油", "柔紫", "海盐", "深空"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    userCard

                    sectionCard(title: "外观", icon: "paintbrush.fill") {
                        SettingsSegment(items: ["跟随系统", "浅色", "深色"], index: $themeMode)
                        hint("跟随系统会适配设备的深浅模式。")
                    }

                    sectionCard(title: "配置", icon: "slider.horizontal.3") {
                        // 线路状态基础展示：永远可见、不跳转。开关配错也不能把用户锁死。
                        lineStatusBaseRow
                        innerDivider
                        if AevisHosts.featureEnabled("serverStatus") {
                            navRow(icon: "server.rack", title: "服务器状态", value: currentLineText) {
                                ServerStatusView()
                            }
                            innerDivider
                        }
                        navRow(icon: "paintbrush", title: "主题配置", value: themeText) {
                            ThemeSettingsView()
                        }
                        hint("服务器状态会实测各条线路延迟，并展示 DeepSeek / 双子星 / Claude 的模型可用率；主题配置可换相册背景图、调位置和模糊。")
                    }

                    sectionCard(title: "消息大小", icon: "textformat.size") {
                        SettingsSegment(items: ["小", "标准", "大"], index: $msgSize)
                    }

                    sectionCard(title: "数据", icon: "icloud.fill") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AE.accent)
                            Text(backup.lastSyncText.isEmpty ? "尚未同步" : backup.lastSyncText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        innerDivider
                        restoreRow
                        hint("恢复只补本机缺少的记录，不会删除或覆盖本地聊天。")
                    }

                    sectionCard(title: "福利与记录", icon: "gift.fill") {
                        navRow(icon: "calendar.badge.checkmark", title: "每日签到", value: "") {
                            CheckInView()
                        }
                        innerDivider
                        // 2026-11-28：QQ 接入（扫码 + 会话内发六位码确认绑定）
                        navRow(icon: "bubble.left.and.bubble.right.fill", title: "QQ 接入", value: "") {
                            QQBindView()
                        }
                        innerDivider
                        if AevisHosts.featureEnabled("growth") {
                            navRow(icon: "person.2.fill", title: "创作者与活动", value: "") {
                                GrowthView()
                            }
                            innerDivider
                        }
                        navRow(icon: "doc.text.magnifyingglass", title: "对话日志", value: "") {
                            ChatLogsView()
                        }
                        hint("入口链接与数据来自服务端，接口未开放时显示「暂无数据」。")
                    }

                    logoutCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                // 原生 TabView 已把底栏安全区让出来，这里只留一点呼吸感
                .padding(.bottom, 40)
            }
            // 铺 AppBackground：ScrollView 自身透明，卡片都是玻璃材质，背景能透上来
            .background(Color.clear)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadProfile() }
            .sheet(isPresented: $showAccount) {
                AccountCenterView()
                    .environmentObject(session)
            }
            .alert("从云端恢复", isPresented: $showRestoreAlert) {
                Button("好", role: .cancel) { }
            } message: {
                Text(restoreMessage)
            }
        }
    }

    // MARK: - 顶部用户卡片（点击进账号中心）

    /// 用户卡片：头像 + 昵称 + 「账号 xxx」/ 会员徽章 + 「账号中心 ›」。
    /// 头像走 `Session.avatar`（登录/冷启动从 `/v1/me` 取），昵称与会员状态在本页拉一次 `/v1/me`。
    /// 底色用品牌主色系（accentDeep → accentLift），深浅模式都是深底白字，对比度稳定。
    private var userCard: some View {
        Button { showAccount = true } label: {
            HStack(spacing: 14) {
                userAvatar

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)

                    HStack(spacing: 6) {
                        if profileLoaded {
                            memberBadge
                        }
                        Text(accountLine)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(1)
                            // 邮箱长了从中间截断，保留域名，别把 @ 后面切没
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    Text("账号中心")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.62))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(userCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius + 4, style: .continuous))
            .shadow(color: AE.accentDeep.opacity(0.26), radius: 12, y: 6)
        }
        .buttonStyle(AevisPressStyle(scale: 0.985))
    }

    /// 卡片底色：品牌主色渐变 + 右上一点白色柔光（不靠边框分层）。
    /// ⚠️ 浅色模式下 `AE.accent` 与 `AE.accentDeep` 是同一个 #2F3A56，渐变会没有层次，
    /// 所以另一端固定用同色系的 `AE.accentLift`（#4A5676），深色模式也不会变成浅蓝底白字。
    private var userCardBackground: some View {
        ZStack {
            LinearGradient(
                colors: [AE.accentLift, AE.accentDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                gradient: Gradient(colors: [Color.white.opacity(0.12), Color.white.opacity(0)]),
                center: UnitPoint(x: 0.82, y: 0.12),
                startRadius: 0, endRadius: 190
            )
        }
    }

    /// 头像 56pt：硬缓存（磁盘 + 条件请求 304），AsyncImage 会每次重新下载且断网就没了。
    /// 空/失败回落「渐变圆底 + 昵称首字」（与 ChatView 同一套视觉）。
    private var userAvatar: some View {
        Group {
            if let url = myAvatarURL {
                CachedRemoteImage(url: url, scope: "user:\(session.email)") {
                    avatarPlaceholder
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1.2))
        .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [AE.accentLift, AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(initialChar)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 56, height: 56)
    }

    /// 会员徽章：半透明白胶囊（深底白字，不用 accentSoft，避免深色模式下糊在卡里）。
    private var memberBadge: some View {
        Text(badgeText)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Color.white.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
    }

    // MARK: - 用户卡片的文案 / 头像地址

    /// 昵称：`/v1/me` 的 nickname → 邮箱前缀 → 「Aevis 用户」。
    private var displayName: String {
        if !nickname.isEmpty { return nickname }
        if !emailPrefix.isEmpty { return emailPrefix }
        return "Aevis 用户"
    }

    private var initialChar: String {
        for ch in displayName where !ch.isWhitespace {
            return String(ch)
        }
        return "A"
    }

    /// 邮箱 @ 前的部分，用作昵称兜底。
    private var emailPrefix: String {
        let e = session.email
        guard !e.isEmpty else { return "" }
        return String(e.split(separator: "@").first ?? "")
    }

    private var accountLine: String {
        session.email.isEmpty ? "账号 —" : "账号 \(session.email)"
    }

    private var badgeText: String {
        guard memberActive else { return "普通用户" }
        return memberDays > 0 ? "会员 · \(memberDays) 天" : "会员"
    }

    /// 头像地址：`Session.avatar` 可能是相对路径，补成当前线路的绝对地址。
    private var myAvatarURL: URL? {
        let s = session.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        let joined = s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s
        return URL(string: joined)
    }

    /// 拉一次 `/v1/me`：昵称 + 会员剩余天数。失败不写任何状态（下次进设置页再试），不阻塞 UI。
    private func loadProfile() async {
        // 2.8：先用硬缓存把昵称 / 会员状态填上没有网络等待，再拉新的覆盖。
        if !profileLoaded, let cached = APIClient.cachedJSON(.memberState, scope: APIClient.cacheScope) {
            await applyProfile(cached)
        }
        guard let token = session.token, !token.isEmpty else { return }
        guard let json = try? await APIClient.me(token: token) else { return }
        await applyProfile(json)
    }

    private func applyProfile(_ json: [String: Any]) async {
        var nick = (json["nickname"] as? String) ?? ""
        if nick.isEmpty {
            let d = (json["data"] as? [String: Any]) ?? json
            nick = (d["nickname"] as? String) ?? ""
        }
        var active = false
        var days = 0
        if let mm = json["membership"] as? [String: Any] {
            active = (mm["active"] as? Bool) ?? false
            days = (mm["days_left"] as? NSNumber)?.intValue ?? 0
        }
        await MainActor.run {
            nickname = nick
            memberActive = active
            memberDays = days
            profileLoaded = true
        }
    }

    // MARK: - 组件

    /// 分组卡：标题行（图标 + 标题）+ 内容，整卡磨砂玻璃。
    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AE.accent)
                Text(title)
                    .font(.system(size: AE.sectionTitle, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    /// 设置行 → 子页面。右侧显示当前状态，样式与其它设置行一致（磨砂卡内一行）。
    private func navRow<Destination: View>(
        icon: String, title: String, value: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AE.textSecondary.opacity(0.45))
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 当前生效线路（自动回落时显示自动选中的那条）。真实值取自 APIClient，不写死。
    private var currentLineText: String {
        APIClient.activeLine.name
    }

    /// 线路状态基础行：只读展示当前线路，不依赖任何功能开关。
    /// 「服务器状态」详情页可以随 flag 隐藏，但这一行始终在，避免开关配错把基础状态也藏掉。
    private var lineStatusBaseRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(width: 22, alignment: .center)
            Text("当前线路")
                .font(.system(size: 14.5))
                .foregroundStyle(AE.textPrimary)
            Spacer(minLength: 8)
            Text(currentLineText)
                .font(.system(size: 12.5))
                .foregroundStyle(AE.textSecondary)
                .lineLimit(1)
        }
        .frame(height: 40)
    }

    /// 当前背景：有自定义图显示「自定义」，否则显示预设名（详细调节在主题配置页）
    private var themeText: String {
        if !bgImagePath.isEmpty { return "自定义" }
        let idx = min(max(bgStyle, 0), bgNames.count - 1)
        return bgNames[idx]
    }

    /// 真实入口：从云端把已备份的聊天记录合并回本机（只补本地没有的）。
    /// 未登录（拿不到 token）时置灰禁用。
    private var restoreRow: some View {
        let available = !(session.token ?? "").isEmpty
        return Button {
            restoreFromCloud()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                Text(restoring ? "正在从云端恢复…" : "从云端恢复聊天记录")
                    .font(.system(size: 14.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 6)
                if restoring {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available || restoring)
        .opacity(available ? 1 : 0.4)
    }

    private func restoreFromCloud() {
        guard let token = session.token, !token.isEmpty, !restoring else { return }
        restoring = true
        Task {
            await CloudBackup.shared.restoreNow(token: token, email: session.email)
            await MainActor.run {
                restoring = false
                restoreMessage = backup.lastSyncText.isEmpty ? "已完成云端恢复。" : backup.lastSyncText
                showRestoreAlert = true
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var innerDivider: some View {
        Rectangle()
            .fill(AE.textSecondary.opacity(0.14))
            .frame(height: 0.7)
    }

    private var logoutCard: some View {
        Button {
            session.signOut()
        } label: {
            Text("退出登录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(AE.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
        .padding(14)
        .frame(maxWidth: .infinity)
        // 磨砂玻璃卡；内部「退出登录」按钮背景 AE.accentSoft 保持实心，保留按钮对比度
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }
}

// MARK: - 三段选择器（选中项白底加粗，照参考图）

/// 私有组件：只在设置页用。选中项是白色圆角块 + 阴影 + semibold，
/// 未选中是次要文字；整条轨道用 accentSoft 淡底。
private struct SettingsSegment: View {
    let items: [String]
    @Binding var index: Int

    private var selectedFill: Color {
        Color.adaptive(dark: Color.hex(0x3C4256), light: .white)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = index == i
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { index = i }
                } label: {
                    Text(items[i])
                        .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AE.textPrimary : AE.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selectedFill)
                                    .shadow(color: Color.black.opacity(0.07), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AE.accentSoft.opacity(0.85))
        )
    }
}
