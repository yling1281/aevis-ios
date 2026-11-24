import SwiftUI

/// 人设广场 / 表情包广场（2026-11-23 新接入）。
///
/// 后端接口已存在且契约稳定，**不改后端**：
/// - `GET /v1/psquare/list` → `data.rows[]`：id/name/tagline/avatar_url/cover_url/adopt_count/is_official
/// - `POST /v1/psquare/adopt` → `data.adoptCount`
/// - `GET /v1/emoji/list` → `data.rows[]`：id/name/intro/cover_url/use_count/items[]/count
/// 取不到一律显示「—」或空态文案，不编造内容；两页共用一个 sheet，从主页服务入口进入。
struct PlazaView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    private let tabs = ["人设广场", "表情包"]
    @State private var tab: Int
    @State private var personas: [APIClient.SquarePersona] = []
    @State private var packs: [APIClient.EmojiPack] = []
    @State private var loading = true
    @State private var failed = false
    @State private var adopted: Set<String> = []
    @State private var expandedPack: String? = nil
    @State private var tip = ""

    init(initialTab: Int = 0) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("广场").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            SegmentedTabs(tabs: tabs, selected: Binding(
                get: { tab },
                set: { new in tab = new }
            ))
            .frame(height: 38)
            .padding(.horizontal, 18)
            .padding(.top, 12)

            ZStack {
                if loading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在加载广场…").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if failed {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30)).foregroundStyle(AE.textSecondary)
                        Text("广场数据获取失败").font(.system(size: 15, weight: .medium)).foregroundStyle(AE.textPrimary)
                        Button { Task { await load() } } label: {
                            Text("重试").font(.system(size: 13, weight: .medium)).foregroundStyle(AE.accent)
                                .padding(.horizontal, 16).frame(height: 32)
                                .background(AE.accentSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == 0 {
                    personaList
                } else {
                    emojiList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if !tip.isEmpty {
                Text(tip).font(.system(size: 12)).foregroundStyle(AE.textSecondary).padding(.bottom, 6)
            }
        }
        .background(AppBackground())
        .task { await load() }
    }

    // MARK: - 加载

    private func load() async {
        await MainActor.run { loading = true; failed = false }
        async let p = APIClient.squarePersonas()
        async let e = APIClient.emojiPacks(token: session.token)
        let ps = try? await p
        let es = try? await e
        await MainActor.run {
            loading = false
            if ps == nil && es == nil {
                failed = true
            } else {
                personas = ps ?? []
                packs = es ?? []
            }
        }
    }

    // MARK: - 人设广场

    private var personaList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                if personas.isEmpty {
                    emptyText("广场还没有已上架的人设")
                } else {
                    ForEach(personas) { p in personaRow(p) }
                }
            }
            .padding(18)
        }
    }

    private func personaRow(_ p: APIClient.SquarePersona) -> some View {
        HStack(alignment: .top, spacing: 11) {
            squareAvatar(p.avatar)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                        .lineLimit(1)
                    if p.isOfficial {
                        Text("官方")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(AE.brandPurple, in: Capsule())
                    }
                }
                if !p.tagline.isEmpty {
                    Text(p.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await adopt(p) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: adopted.contains(p.id) ? "heart.fill" : "heart")
                        Text("采用 \(adopted.contains(p.id) ? p.adoptCount + 1 : p.adoptCount)")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(adopted.contains(p.id) ? AE.brandPurple : AE.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(adopted.contains(p.id))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.16)
    }

    @MainActor
    private func adopt(_ p: APIClient.SquarePersona) async {
        do {
            _ = try await APIClient.adoptPersona(id: p.id)
            adopted.insert(p.id)
        } catch {
            showTip("采用失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 表情包广场

    private var emojiList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                if packs.isEmpty {
                    emptyText("广场还没有已上架的表情包")
                } else {
                    ForEach(packs) { pack in emojiPackRow(pack) }
                }
            }
            .padding(18)
        }
    }

    private func emojiPackRow(_ pack: APIClient.EmojiPack) -> some View {
        let open = expandedPack == pack.id
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.18)) {
                expandedPack = open ? nil : pack.id
            } } label: {
                HStack(alignment: .center, spacing: 11) {
                    squareAvatar(pack.cover)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pack.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                            .lineLimit(1)
                        if !pack.intro.isEmpty {
                            Text(pack.intro)
                                .font(.system(size: 12))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(2)
                        }
                        Text("\(pack.count) 张 · 被使用 \(pack.useCount) 次")
                            .font(.system(size: 11))
                            .foregroundStyle(AE.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AE.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if open && !pack.items.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Array(pack.items.enumerated()), id: \.offset) { pair in
                        AsyncImage(url: resolveURL(pair.element)) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFit()
                                    .frame(height: 62)
                                    .glassCard(cornerRadius: 10, material: .thin)
                            default:
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(AE.accentSoft)
                                    .frame(height: 62)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.16)
    }

    // MARK: - 通用

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }

    private func squareAvatar(_ path: String) -> some View {
        Group {
            if let url = resolveURL(path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        ZStack {
                            AE.accentSoft
                            Image(systemName: "sparkles").foregroundStyle(AE.textSecondary)
                        }
                    }
                }
            } else {
                ZStack {
                    AE.accentSoft
                    Image(systemName: "sparkles").foregroundStyle(AE.textSecondary)
                }
            }
        }
        .frame(width: 46, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 后端 media 字段可能是绝对 URL，也可能是 `/v1/media/...` 相对路径。
    private func resolveURL(_ raw: String) -> URL? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") { return URL(string: raw) }
        return URL(string: APIClient.base + raw)
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
