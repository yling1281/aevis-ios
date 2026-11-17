import SwiftUI

/// 会话列表（2026-11-17，134 骨架 → 140 对齐安卓）。
///
/// 对齐点（与安卓 `ChatTab` 的 `PersonRow` 一致）：
///   · 行高 56、左右内边距 16；
///   · 左侧 46pt 头像（无图走首字圆底）；
///   · 名字 15pt、最后一条消息 11pt 截断单行；
///   · 右侧时间 `HH:mm`（当天）/ `MM-dd`（更早）；
///   · 有主动消息未读时，名字右侧一个浅紫「TA 找你了」；
///   · 空态：居中线条猫 + 一句「还没有自己的角色」。
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
            Group {
                if personas.isEmpty && !loading {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("聊天")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(AE.accent)
                    }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(personas) { p in
                NavigationLink {
                    ChatView(persona: p)
                } label: {
                    row(p)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: AE.cardPadding,
                                          bottom: 0, trailing: AE.cardPadding))
            }
        }
        .listStyle(.plain)
    }

    private func row(_ p: Persona) -> some View {
        HStack(spacing: 12) {
            avatar(p)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: AE.body, weight: .medium))
                        .lineLimit(1)
                    if LocalStore.unread(p.id) > 0 {
                        Text("TA 找你了")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(AE.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(AE.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer(minLength: 0)
                }
                Text(lastText(p))
                    .font(.system(size: AE.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(timeText(p.id))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .frame(height: AE.rowHeight)
        .contentShape(Rectangle())
    }

    private func avatar(_ p: Persona) -> some View {
        AsyncImage(url: URL(string: abs(p.avatar))) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Text(String(p.name.prefix(1)))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(width: 46, height: 46)
                .background(AE.accent.opacity(0.14))
                .clipShape(Circle())
        }
        .frame(width: 46, height: 46)
        .clipShape(Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cat")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(error.isEmpty ? "还没有自己的角色" : error)
                .font(.system(size: AE.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
