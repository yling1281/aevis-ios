import SwiftUI

/// 角色列表（2026-11-17，134 骨架）。空态也给，别留白屏。
struct ChatListView: View {
    @EnvironmentObject private var session: Session
    @State private var personas: [Persona] = []
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if personas.isEmpty && !loading {
                    VStack(spacing: 8) {
                        Image(systemName: "cat")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(error.isEmpty ? "还没有自己的角色" : error)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowSeparator(.hidden)
                }
                ForEach(personas) { p in
                    NavigationLink {
                        ChatView(persona: p)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: abs(p.avatar))) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.secondary.opacity(0.15))
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.body)
                                Text(p.tagline.isEmpty ? "还没有聊过" : p.tagline)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("聊天")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("设置") { }
                        .opacity(0)   // 骨架：入口先占位，避免死链
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await reload() }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    /// 头像可能是 `/v1/media/...` 这种相对路径，拼上 BASE 再交给 AsyncImage。
    private func abs(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("http") { return path }
        if path.hasPrefix("/") { return APIClient.base + path }
        return path
    }

    private func reload() async {
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
