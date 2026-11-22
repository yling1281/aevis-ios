import SwiftUI

/// 会话列表（2026-11-22 视觉重做）。
///
/// 大标题头图 + 卡片式角色行 + 有温度的空态。
///   · 顶部：「聊天」大标题 + 一句轻描述 + 角色数，不再只有一个小导航标题；
///   · 行：圆角卡片、内边距、头像柔底、名字/时间层级、最后一条消息预览；
///   · 角标：未读「TA 找你了」重做成精致小胶囊；
///   · 空态：叠放圆形轻插画 + 一句引导，并告知入口在哪。
///
/// 功能保持不变：demo 分支（CI 截图）、reload()、lastText/timeText/abs、点行进 ChatView 都不动。
struct ChatListView: View {
    @EnvironmentObject private var session: Session
    /// 云端备份：恢复确认弹框、手动恢复入口都靠它。
    @ObservedObject private var backup = CloudBackup.shared

    /// 140：CI 截图用（`-demo list`），Release 编不进去
    #if DEBUG
    var demo: Bool = false
    #endif

    @State private var personas: [Persona] = []
    @State private var loading = false
    @State private var error = ""
    /// 离线轻提示：拉接口失败但有本地缓存时显示一行字，**不清空列表/不弹错误页**。
    @State private var offlineHint = ""
    /// 手动「从云端恢复」的结果提示（几秒后自动消失）。
    @State private var restoreToast = ""
    /// 长按菜单选中的「要打开角色设置」的角色。
    @State private var settingsPersona: Persona?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header

                    if personas.isEmpty && !loading {
                        emptyState
                    } else {
                        list
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Color.paper)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await reload() }
                        } label: {
                            Label("刷新", systemImage: "arrow.triangle.2.circlepath")
                        }
                        // 手动补恢复入口（设置页不让改，这里给一个随时可用的入口）
                        Button {
                            Task { await manualRestore() }
                        } label: {
                            Label("从云端恢复", systemImage: "arrow.down.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(AE.accent)
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            // 「先问再恢复」确认框（检测到云端有数据时由 CloudBackup 置 pendingRestore）
            .alert(
                "检测到云端聊天记录",
                isPresented: Binding(
                    get: { backup.pendingRestore != nil },
                    // alert 只能通过按钮关闭：「恢复」调 confirmRestore、「暂不恢复」调 declineRestore，
                    // 两者都会把 pendingRestore 置 nil。这里 set 必须留空 —— 否则点「恢复」时
                    // 系统触发的 dismiss 会抢在 confirmRestore 前把 pendingRestore 当成「拒绝」。
                    set: { _ in }
                ),
                presenting: backup.pendingRestore
            ) { _ in
                Button("恢复") {
                    Task {
                        await backup.confirmRestore()
                        await reload()
                        showToast("已从云端恢复")
                    }
                }
                Button("暂不恢复", role: .cancel) {
                    backup.declineRestore()
                }
            } message: { p in
                Text("云端有 \(p.convCount) 个会话、共 \(p.msgCount) 条聊天记录（来自安卓）。是否恢复到本机？恢复只补充不覆盖，本地已有记录不会丢。")
            }
            // 手动恢复结果提示
            .overlay(alignment: .bottom) {
                if !restoreToast.isEmpty {
                    Text(restoreToast)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(AE.accentDeep.opacity(0.92)))
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// 手动「从云端恢复」：清拒绝 flag → 拉取合并 → 提示 + 重载列表。
    @MainActor
    private func manualRestore() async {
        guard let token = session.token, !token.isEmpty else {
            showToast("请先登录")
            return
        }
        await backup.restoreNow(token: token, email: session.email)
        await reload()
        showToast(backup.lastSyncText.isEmpty ? "已尝试从云端恢复" : backup.lastSyncText)
    }

    @MainActor
    private func showToast(_ text: String) {
        withAnimation { restoreToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { withAnimation { restoreToast = "" } }
        }
    }

    // MARK: - 头图

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("聊天")
                .font(.system(size: AE.heroTitle, weight: .bold, design: .rounded))
                .foregroundStyle(AE.textPrimary)
            Text("和你在意的人，说说话。")
                .font(.system(size: 14))
                .foregroundStyle(AE.textSecondary)
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill").font(.system(size: 10))
                Text("\(personas.count) 个角色")
                Text("·")
                Text(loading ? "正在同步…" : (offlineHint.isEmpty ? "下拉可刷新" : offlineHint))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary.opacity(0.85))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    // MARK: - 列表

    private var list: some View {
        LazyVStack(spacing: 12) {
            ForEach(personas) { p in
                NavigationLink {
                    ChatView(persona: p)
                } label: {
                    row(p)
                }
                .buttonStyle(.plain)
                // 长按 → 角色设置（不占用行内空间，不破坏现有布局）
                .contextMenu {
                    Button {
                        settingsPersona = p
                    } label: {
                        Label("角色设置", systemImage: "slider.horizontal.3")
                    }
                }
            }
        }
        // 长按菜单选「角色设置」→ sheet 呈现（NavigationStack 包裹以支持标题）
        .sheet(item: $settingsPersona) { p in
            NavigationStack {
                CharacterSettingsView(persona: p)
            }
        }
    }

    private func row(_ p: Persona) -> some View {
        HStack(spacing: 14) {
            avatar(p)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(p.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                        .lineLimit(1)
                    if LocalStore.unread(p.id) > 0 { unreadBadge }
                    Spacer(minLength: 0)
                }
                Text(lastText(p))
                    .font(.system(size: 13))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 10) {
                Text(timeText(p.id))
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textSecondary.opacity(0.8))
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AE.textSecondary.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(height: AE.rowHeight)
        // 磨砂玻璃卡（.regular 更实）；内部头像/文字/未读徽标与点击热区全部保留
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
        .contentShape(Rectangle())
    }

    private var unreadBadge: some View {
        HStack(spacing: 4) {
            Circle().fill(AE.warm).frame(width: 5, height: 5)
            Text("TA 找你了")
                .font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(AE.accent)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(AE.accentSoft)
        .clipShape(Capsule())
    }

    private func avatar(_ p: Persona) -> some View {
        AsyncImage(url: URL(string: abs(p.avatar))) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [AE.accentLift, AE.accentDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                Text(String(p.name.prefix(1)))
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
        .shadow(color: AE.shadowColor, radius: 4, y: 2)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(AE.accentSoft).frame(width: 112, height: 112)
                Circle().fill(AE.accent.opacity(0.10))
                    .frame(width: 78, height: 78).offset(x: 26, y: -10)
                Circle().fill(AE.warm.opacity(0.14))
                    .frame(width: 44, height: 44).offset(x: -30, y: 24)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AE.accent)
            }
            .frame(height: 140)

            Text(error.isEmpty ? "这里还空着" : error)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(AE.textPrimary)
                .multilineTextAlignment(.center)

            Text("去「我的 → 人设库」添加一个属于你的人吧，\nTa 就会在这里等你。")
                .font(.system(size: 13.5))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .padding(.horizontal, 24)
    }

    // MARK: - 数据

    private func lastText(_ p: Persona) -> String {
        let msgs = LocalStore.load(pid: p.id)
        guard let last = msgs.last else { return "还没有聊过" }
        if !last.img.isEmpty { return "[图片]" }
        return last.content.isEmpty ? "还没有聊过" : last.content
    }

    private func timeText(_ pid: String) -> String {
        guard let d = LocalStore.lastAt(pid) else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MM-dd"
        return f.string(from: d)
    }

    private func abs(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("http") { return path }
        if path.hasPrefix("/") { return APIClient.base + path }
        return path
    }

    private func reload() async {
        #if DEBUG
        if demo {
            // 截图用的样例：三条角色、一条带未读、两条有最后消息 → 行高/时间/角标都能被拍到
            LocalStore.save(pid: "demo_persona", msgs: [
                Msg(role: "assistant", content: "（把茶推到你手边）先喝口水。")
            ])
            LocalStore.save(pid: "demo_2", msgs: [
                Msg(role: "assistant", content: "今晚早点睡，别又熬到三点。")
            ])
            LocalStore.setUnread("demo_persona", 2)
            personas = [
                Persona(id: "demo_persona", name: "季焚时", tagline: "", avatar: ""),
                Persona(id: "demo_2", name: "沈砚之", tagline: "", avatar: ""),
                Persona(id: "demo_3", name: "零砚", tagline: "", avatar: "")
            ]
            return
        }
        #endif

        // ① 先把本地缓存「立刻」顶上 —— 断网/服务端挂了也不能整屏空白（用户硬要求）
        let cached = LocalStore.loadPersonas()
        let local = cached.isEmpty ? LocalStore.fallbackPersonas() : cached
        if !local.isEmpty { personas = local }
        offlineHint = ""

        guard let token = session.token else {
            // 未登录：有本地就显示本地记录，没有就走空态（提示去登录/添加）
            return
        }
        loading = true; error = ""
        do {
            let fresh = try await APIClient.myPersonas(token: token, email: session.email)
            if !fresh.isEmpty {
                personas = fresh
                LocalStore.savePersonas(fresh)      // 存本地，下次断网直接用
            }
            error = ""
        } catch {
            // 失败：**保留本地缓存**，只在头部加一行轻提示，不清空列表、不进错误页
            if !personas.isEmpty {
                offlineHint = "离线，显示本地记录"
            } else {
                self.error = "拉取角色失败：\(error.localizedDescription)"
            }
        }
        loading = false
    }
}
