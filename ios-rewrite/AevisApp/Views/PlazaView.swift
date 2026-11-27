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

    /// 2.8：从主页右滑进入全屏二级菜单时由外层注入关闭动作；
    /// 独立 sheet 展示时走系统 dismiss。两种入口都不写死返回方式。
    var onClose: (() -> Void)? = nil

    private let tabs = ["人设广场", "表情包"]
    @State private var tab: Int
    /// 切 tab 的方向（true = 往后翻，从右进）。转场方向要跟手势方向一致，
    /// 否则从第二个 tab 切回第一个时还会"从右进"，看着像又往前走了一步。
    @State private var forward = true
    @State private var personas: [APIClient.SquarePersona] = []
    @State private var packs: [APIClient.EmojiPack] = []
    @State private var loading = true
    @State private var failed = false
    @State private var adopted: Set<String> = []
    @State private var expandedPack: String? = nil
    @State private var tip = ""
    /// 创建人设（后端 `/v1/psquare/publish` 已存在，之前广场页缺入口 → 用户「添加不了」）
    @State private var showCreate = false
    /// 硬缓存：连不上服务器时为 true，页面顶部提示，但列表照常显示本地缓存
    @State private var offline = false
    @State private var cacheHint = ""

    init(initialTab: Int = 0, onClose: (() -> Void)? = nil) {
        _tab = State(initialValue: initialTab)
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { close() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text("广场").font(.system(size: 17, weight: .semibold)).foregroundStyle(AE.textPrimary)
                Spacer()
                // 人设页才有「创建」：这就是用户反馈「添加不了」的根因——之前只有采用按钮
                if tab == 0 {
                    Button { showCreate = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AE.brandPurple)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("创建人设")
                } else {
                    Color.clear.frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            if offline {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 11))
                    Text("连不上服务器，当前显示本地缓存\(cacheHint)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(AE.textSecondary)
                .padding(.horizontal, 18)
                .padding(.top, 6)
            }

            SegmentedTabs(tabs: tabs, selected: Binding(
                get: { tab },
                set: { new in
                    guard new != tab else { return }
                    // 转场从右往左（AEMotion.pageTransition）：新页从右进、旧页往左出，
                    // 和方向一致才像"翻页"。注意要先把方向存下来，再用 withAnimation 切。
                    forward = new > tab
                    withAnimation(AEMotion.pageAnimation) { tab = new }
                }
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
                        .id("persona")
                        .transition(forward ? AEMotion.pageTransition
                                            : AEMotion.pageTransitionBackward)
                } else {
                    emojiList
                        .id("emoji")
                        .transition(forward ? AEMotion.pageTransition
                                            : AEMotion.pageTransitionBackward)
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
        .sheet(isPresented: $showCreate) {
            PersonaCreateView { _ in
                Task { await load() }
            }
            .environmentObject(session)
        }
    }

    // MARK: - 加载（磁盘硬缓存优先）

    private func load() async {
        // 1) 同步读磁盘：2.8 起优先读统一硬缓存（登录预加载已落盘），
        //    再退回旧的 PlazaCacheStore，保证升级用户不会看到空页。
        let disk = PlazaCacheStore.load()
        let hardPersonas = APIClient.cachedJSON(.squarePersonas)
            .map(APIClient.parseSquarePersonas) ?? []
        let hardPacks = APIClient.cachedJSON(.emojiPacks)
            .map(APIClient.parseEmojiPacks) ?? []
        let cachedPersonas = hardPersonas.isEmpty ? disk.personas : hardPersonas
        let cachedPacks = hardPacks.isEmpty ? disk.packs : hardPacks
        let hadCache = !cachedPersonas.isEmpty || !cachedPacks.isEmpty
        await MainActor.run {
            personas = cachedPersonas
            packs = cachedPacks
            offline = false
            let at = max(disk.checkedAt, HardCache.savedAt(.squarePersonas))
            cacheHint = at > 0 ? "（更新于 \(Self.timeText(at))）" : ""
            loading = !hadCache
            failed = false
        }

        // 2) 云端拉取；任一成功就按内容签名决定是否覆盖缓存
        async let p = APIClient.squarePersonas()
        async let e = APIClient.emojiPacks(token: session.token)
        let ps = try? await p
        let es = try? await e
        guard ps != nil || es != nil else {
            await MainActor.run {
                // 连不上：保留本地缓存，只有完全没有缓存时才显示失败页
                loading = false
                failed = !hadCache
                offline = hadCache
            }
            return
        }
        let newPersonas = ps ?? cachedPersonas
        let newPacks = es ?? cachedPacks
        let sig = PlazaCacheStore.signature(personas: newPersonas, packs: newPacks)
        let changed = sig != disk.signature
        if changed {
            PlazaCacheStore.save(PlazaCacheStore.Payload(
                personas: newPersonas, packs: newPacks,
                signature: sig, checkedAt: Date().timeIntervalSince1970))
        }
        await MainActor.run {
            personas = newPersonas
            packs = newPacks
            loading = false
            failed = false
            // 一半接口失败时也提示，但列表仍是缓存+另一半的新数据
            offline = ps == nil || es == nil
            if !changed { cacheHint = "（内容未变）" }
        }
    }

    private static func timeText(_ epoch: Double) -> String {
        let d = Date(timeIntervalSince1970: epoch)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 人设广场

    private var personaList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 10) {
                if personas.isEmpty {
                    emptyText("广场还没有已上架的人设")
                } else {
                    ForEach(Array(personas.enumerated()), id: \.element.id) { pair in
                        personaRow(pair.element).staggerIn(min(pair.offset, 4))
                    }
                }
            }
            .padding(18)
        }
    }

    private func personaRow(_ p: APIClient.SquarePersona) -> some View {
        HStack(alignment: .top, spacing: 11) {
            squareAvatar(p.avatar, scope: "persona:\(p.id)")
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
            // 带 token：后端据此把我的采用记录写进人设库，聊天列表才看得到这个人设
            _ = try await APIClient.adoptPersona(id: p.id, token: session.token)
            adopted.insert(p.id)
            showTip("已加入我的角色，可在聊天列表找到")
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
                    ForEach(Array(packs.enumerated()), id: \.element.id) { pair in
                        emojiPackRow(pair.element).staggerIn(min(pair.offset, 4))
                    }
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
                    squareAvatar(pack.cover, scope: "pack:\(pack.id)")
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
                        CachedRemoteImage(
                            url: resolveURL(pair.element),
                            scope: "pack:\(pack.id):\(pair.offset)"
                        ) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(AE.accentSoft)
                        }
                        .frame(height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private func squareAvatar(_ path: String, scope: String) -> some View {
        // 2.8 修「广场头像加载不出来」：AsyncImage 用 URLSession.shared，
        // 直连自签证书必然失败；CachedRemoteImage 统一走硬缓存 + 线路 session。
        CachedRemoteImage(url: resolveURL(path), scope: scope) {
            ZStack {
                AE.accentSoft
                Image(systemName: "sparkles").foregroundStyle(AE.textSecondary)
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

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
