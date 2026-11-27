import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// 三点二级菜单当前针对的角色（2026-11-27）。
    @State private var menuPersona: Persona?
    /// 编辑人设（菜单入口）：单独一个 sheet，避免和角色设置混用。
    @State private var editPersona: Persona?
    /// 点行进入聊天：不再用 NavigationLink 包整行，否则行内三点会被链接吞掉点击。
    @State private var openPersona: Persona?
    /// 重命名备注。
    @State private var renameTarget: Persona?
    @State private var renameText = ""
    /// 导出：生成文件后弹系统分享。
    @State private var shareURL: URL?
    @State private var showImporter = false
    @State private var actionToast = ""

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
            .background(Color.clear)   // 背景统一由 MainTabView 最底层提供
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
            .onReceive(NotificationCenter.default.publisher(for: CharacterSettingsView.personaUpdated)) { _ in
                Task { await reload() }
            }
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

    /// 置顶的排最前，其余保持服务端给的顺序（不重排，避免列表跳来跳去）。
    private var orderedPersonas: [Persona] {
        let pinned = personas.filter { LocalStore.isPinned($0.id) }
        let rest = personas.filter { !LocalStore.isPinned($0.id) }
        return pinned + rest
    }

    private var list: some View {
        LazyVStack(spacing: 12) {
            ForEach(orderedPersonas) { p in
                Button {
                    openPersona = p
                } label: {
                    row(p)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottomTrailing) {
                    // 三点点位在行按钮之上，独立响应；不会被「进聊天」吞掉。
                    Button {
                        menuPersona = p
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AE.textSecondary.opacity(0.55))
                            .frame(width: 40, height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 2)
                    .padding(.bottom, 4)
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { openPersona != nil },
            set: { if !$0 { openPersona = nil } }
        )) {
            if let p = openPersona { ChatView(persona: p) }
        }
        // 角色设置（长按/菜单共用同一个 sheet）
        .sheet(item: $settingsPersona) { p in
            NavigationStack {
                CharacterSettingsView(persona: p)
            }
        }
        // 编辑人设（菜单入口）
        .sheet(item: $editPersona) { p in
            NavigationStack {
                CharacterSettingsView(persona: p, startInProfileEdit: true)
            }
        }
        // 三点二级菜单：自绘面板（不用系统 Menu）
        .sheet(item: $menuPersona) { p in
            ConvMenuSheet(
                name: LocalStore.displayName(p.id, fallback: p.name),
                avatar: avatarURL(p),
                pinned: LocalStore.isPinned(p.id),
                hasMessages: !LocalStore.load(pid: p.id).isEmpty,
                onSettings: { settingsPersona = p },
                onEditProfile: { editPersona = p },
                onTogglePin: {
                    let on = LocalStore.togglePinned(p.id)
                    actionToast = on ? "已置顶" : "已取消置顶"
                },
                onRename: {
                    renameText = LocalStore.alias(p.id)
                    renameTarget = p
                },
                onExport: exportChats,
                onImport: { showImporter = true },
                onClear: {
                    LocalStore.clearConv(p.id)
                    actionToast = "已清空本会话"
                },
                onDelete: {
                    LocalStore.deleteConv(p.id)
                    personas.removeAll { $0.id == p.id }
                    actionToast = "已删除会话"
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL { ActivityView(items: [url]) }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let r = try LocalStore.importChatArchive(from: url)
                    actionToast = "已导入 \(r.convs) 个会话，新增 \(r.msgs) 条"
                    Task { await reload() }
                } catch {
                    actionToast = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let e):
                actionToast = "导入失败：\(e.localizedDescription)"
            }
        }
        .alert("重命名备注", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("给她起个名字", text: $renameText)
            Button("保存") {
                if let p = renameTarget { LocalStore.setAlias(p.id, renameText) }
                renameTarget = nil
                actionToast = "已保存备注"
            }
            Button("取消", role: .cancel) { renameTarget = nil }
        } message: {
            Text("只改本机显示名，不影响角色本身。")
        }
        .overlay(alignment: .bottom) {
            if !actionToast.isEmpty {
                Text(actionToast)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(AE.accentDeep.opacity(0.92)))
                    .padding(.bottom, 18)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        actionToast = ""
                    }
            }
        }
    }

    private func exportChats() {
        if let url = LocalStore.exportChatArchive() {
            shareURL = url
        } else {
            actionToast = "导出失败，请重试"
        }
    }

    private func row(_ p: Persona) -> some View {
        HStack(spacing: 14) {
            avatar(p)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // 备注名优先：用户自己起的名字盖过角色原名（本地生效，不写服务端）
                    Text(LocalStore.displayName(p.id, fallback: p.name))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                        .lineLimit(1)
                    if LocalStore.isPinned(p.id) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AE.accent.opacity(0.75))
                    }
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
                // 右下角留给三点按钮（overlay 定位到同一位置）
                Color.clear.frame(width: 20, height: 18)
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

    /// 角色头像：磁盘硬缓存优先（`CachedRemoteImage`），没有缓存才显示渐变底 + 首字；
    /// 后台带 ETag 条件请求，服务器说变了才换图，断网一直用旧图。
    private func avatar(_ p: Persona) -> some View {
        CachedRemoteImage(url: avatarURL(p), scope: "persona:\(p.id)") {
            avatarPlaceholder(p)
        }
        .frame(width: 52, height: 52)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
        .shadow(color: AE.shadowColor, radius: 4, y: 2)
    }

    private func avatarPlaceholder(_ p: Persona) -> some View {
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
        .frame(width: 52, height: 52)
    }

    /// 头像地址：空 → nil（走占位）。`abs()` 已把相对路径拼成绝对地址。
    private func avatarURL(_ p: Persona) -> URL? {
        let s = abs(p.avatar).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return URL(string: s)
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
        let cached = LocalStore.loadPersonas().map(CharacterSettingsView.applyOverrides)
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
                // 2.9：服务端角色卡没有名字/头像编辑接口，本地覆盖要在每次刷新时叠回去。
                let merged = fresh.map(CharacterSettingsView.applyOverrides)
                personas = merged
                LocalStore.savePersonas(fresh)      // 本地缓存仍存原始服务端数据
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

// MARK: - 会话二级菜单（2026-11-27）
//
// 用户要求「点人物三点，自己做二级菜单」，所以这里不用系统 Menu / contextMenu，
// 统一一张自绘卡片：角色操作 + 数据操作 + 危险操作三段，视觉与 App 其它面板一致。

struct ConvMenuSheet: View {
    let name: String
    let avatar: URL?
    let pinned: Bool
    let hasMessages: Bool
    /// 会话页里不需要「导入整包」（那是列表页的事），传 false 隐藏这一行。
    var showsImport: Bool = true

    var onSettings: () -> Void = {}
    var onEditProfile: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRename: () -> Void = {}
    var onExport: () -> Void = {}
    var onImport: () -> Void = {}
    var onClear: () -> Void = {}
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                header
                group {
                    item("slider.horizontal.3", "角色设置") { fire(onSettings) }
                    sep
                    item("person.crop.circle", "编辑人设") { fire(onEditProfile) }
                    sep
                    item("pin", pinned ? "取消置顶" : "置顶会话") { fire(onTogglePin) }
                    sep
                    item("pencil", "重命名备注") { fire(onRename) }
                }
                group {
                    item("square.and.arrow.up", "导出聊天记录") { fire(onExport) }
                    if showsImport {
                        sep
                        item("square.and.arrow.down", "导入聊天记录") { fire(onImport) }
                    }
                    sep
                    item("eraser", "清空本会话") { fire(onClear) }
                        .disabled(!hasMessages)
                        .opacity(hasMessages ? 1 : 0.4)
                }
                group {
                    item("trash", "删除会话", danger: true) { fire(onDelete) }
                }
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .glassCard(cornerRadius: 16, material: .thin, tintOpacity: 0.08)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 26)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CachedRemoteImage(url: avatar, scope: "menu:\(name)") {
                Circle().fill(AE.accentSoft)
                    .overlay(
                        Text(String(name.prefix(1)))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AE.accent)
                    )
            }
            .frame(width: 42, height: 42)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)
                Text(pinned ? "已置顶 · 记录存本机" : "记录存本机 · 不上传")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func group<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .glassCard(cornerRadius: 16, material: .regular, tintOpacity: 0.08)
    }

    private var sep: some View {
        Rectangle().fill(AE.cardStroke.opacity(0.16))
            .frame(height: 0.5).padding(.leading, 46)
    }

    private func item(_ icon: String, _ title: String,
                      danger: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(danger ? Color.red : AE.accent)
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(danger ? Color.red : AE.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fire(_ action: @escaping () -> Void) {
        dismiss()
        // sheet 收起动画期间改父状态容易被吞，挪到下一轮 runloop。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { action() }
    }
}

/// 系统分享面板（导出聊天记录用）。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
