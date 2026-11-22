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

    /// 140：CI 截图用（`-demo list`），Release 编不进去
    #if DEBUG
    var demo: Bool = false
    #endif

    @State private var personas: [Persona] = []
    @State private var loading = false
    @State private var error = ""

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
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(AE.accent)
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
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
                Text(loading ? "正在同步…" : "下拉可刷新")
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
        .background(AE.card)
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous))
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

        guard let token = session.token else { return }
        loading = true; error = ""
        do {
            personas = try await APIClient.myPersonas(token: token, email: session.email)
        } catch {
            self.error = "拉取角色失败：\(error.localizedDescription)"
        }
        loading = false
    }
}
