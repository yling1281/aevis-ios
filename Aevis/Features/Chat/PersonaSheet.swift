import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「TA 的资料」—— 聊天页右上角点进来的那一页。
///
/// ## 为什么要有它（用户原话）
/// 「打开这个人的右上角，为什么跟设置一样的？联系人右上角应该是给对方改头像、
/// 姓名、聊天人设、背景图之类的呀」
///
/// 以前那个位置是个**全局设置**按钮 —— 点开的是"整个 App 的设置"，
/// 跟你正在跟谁聊天一点关系都没有。现在这一页只放**和这个人有关**的东西。
struct PersonaSheet: View {

    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings

    @Environment(\.dismiss) private var dismiss

    @State private var pickedAvatar: PhotosPickerItem?
    @State private var editing = false
    @State private var showClearConfirm = false
    /// #24（2026-09-30）：看 TA 的钱包改成从这里点进去。
    @State private var showTaWallet = false
    /// ⭐ 2026-10-04：从电脑版同步过来的三样 —— 个性标签 / 她的歌单 / 一起玩。
    @State private var showTags = false
    @State private var showPlaylist = false
    @State private var showMC = false
    @State private var note: String?

    private var persona: Persona { personaStore.persona }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    avatarCard
                    editCard
                    dangerCard

                    if let note {
                        Text(note)
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("TA 的资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $editing) {
                PersonaEditorView(isFirstRun: false)
            }
            .confirmationDialog("清空和 TA 的聊天记录？",
                                isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    chatClear()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删聊天记录，人设、记忆、头像都留着。删了找不回来 —— 先导一份备份更稳妥。")
            }
            .sheet(isPresented: $showTaWallet) {
                TaWalletSheet()
            }
            // ⭐ 2026-10-04：个性标签 / 她的歌单 / 一起玩。
            .sheet(isPresented: $showTags) {
                PersonaTagSheet()
            }
            .sheet(isPresented: $showPlaylist) {
                HerPlaylistSheet()
            }
            .sheet(isPresented: $showMC) {
                MCView()
            }
            .onChange(of: pickedAvatar) { _, item in
                guard let item else { return }
                loadAvatar(item)
            }
        }
    }

    // MARK: - 头像与名字

    private var avatarCard: some View {
        VStack(spacing: 12) {
            AevisAvatar(size: 84, seed: persona.avatarSeed)

            VStack(spacing: 3) {
                Text(persona.name.isEmpty ? "还没起名字" : persona.name)
                    .font(.aevis(19, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("性别：" + persona.gender.label + "　·　该怎么称呼由它决定")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            }

            // ⭐ 2026-10-04：个性标签 —— 几个字的短签，一眼看出她的性子。
            if !persona.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(persona.tags.prefix(4), id: \.self) { tag in
                        Text(tag)
                            .font(.aevis(11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }

            HStack(spacing: 10) {
                PhotosPicker(selection: $pickedAvatar, matching: .images) {
                    Text("换头像")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                // PhotosPicker 的文字会被系统刷成强调色，要显式压回来
                .tint(Color.primary)

                if personaStore.avatarImage != nil {
                    Button {
                        personaStore.setAvatar(nil)
                        note = "自定义头像删掉了，换回自动生成的那个。"
                    } label: {
                        Text("删掉头像")
                            .font(.aevis(14))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 能改的东西

    private var editCard: some View {
        VStack(spacing: 0) {
            // ⚠️⚠️ **这一页只留「编辑资料」**（用户 2026-09-28 原话：
            //    「我说了好多遍了，就是右上角的话，就只有编辑资料」）。
            //
            // 以前这里还挂着两行：
            //   ·「聊天背景与外观」→ 其实开的是**整个设置页**（20 多张卡），
            //     他每次都要骂一次"说了多少遍不要全部设置"
            //   ·「TA 的朋友圈」→ 看朋友圈在「发现」那一页，这里不需要第二个入口
            // 两行都撤了。外观设置仍在「设置 → 外观」里，功能一个没少。
            row("编辑资料", "名字、性别、性格、说话方式、关系、音色") {
                editing = true
            }
            // #24（2026-09-30）：看 TA 的钱包从这儿点进去（钱包页里不再显示 TA 余额）。
            row("TA 的钱包", WalletStore.money(WalletStore.shared.taBalance)) {
                showTaWallet = true
            }
            // ⭐ 2026-10-04：从电脑版同步过来的三样。
            row("个性标签", tagLine) {
                showTags = true
            }
            row("她的歌单", "她在你网易云里收藏的那些歌") {
                showPlaylist = true
            }
            row("一起玩", "选一种玩法，陪你在《我的世界》里过一天") {
                showMC = true
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private var tagLine: String {
        persona.tags.isEmpty ? "还没贴标签，点一下加几个" : persona.tags.joined(separator: " · ")
    }

    private var dangerCard: some View {
        VStack(spacing: 0) {
            Button {
                showClearConfirm = true
            } label: {
                HStack {
                    Text("清空和 TA 的聊天记录")
                        .font(.aevis(15))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 动作

    private func chatClear() {
        ChatStore.shared.clear()
        note = "聊天记录清空了，人设和记忆都留着。"
    }

    private func loadAvatar(_ item: PhotosPickerItem) {
        note = nil
        Task { @MainActor in
            defer { pickedAvatar = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                note = "这张图读不出来，换一张试试。"
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                note = "这张图格式不支持，换成 JPG 或 PNG 再试。"
                return
            }
            personaStore.setAvatar(image, original: data)
            note = "头像换好了。"
            #else
            note = "这个平台上换不了头像。"
            #endif
        }
    }

    // MARK: - 零件

    private func row(_ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.aevis(13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

/// #24（2026-09-30）：从「TA 的资料」点进来的 TA 钱包（只读，假数据）。
struct TaWalletSheet: View {
    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var personaStore = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    private var personaName: String {
        let name = personaStore.persona.name
        return name.isEmpty ? "TA" : name
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(WalletStore.money(wallet.taBalance))
                    .font(.aevis(34, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("\(personaName)的钱包")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                Text("这也是本机上的假数据 —— 不接真钱，也不会真的从谁那里扣。")
                    .font(.aevis(12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer(minLength: 0)
            }
            .padding(.top, 54)
            .frame(maxWidth: .infinity)
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("TA 的钱包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 个性标签（2026-10-04）

/// 给 TA 贴几个个性标签。几个字的短签，资料页上一眼看出她的性子。
struct PersonaTagSheet: View {

    @ObservedObject private var personaStore = PersonaStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""

    private var accent: Color { settings.accentColor }
    private var tags: [String] { personaStore.persona.tags }

    /// 懒得想的现成备选。
    private static let suggestions = [
        "嘴硬心软", "夜猫子", "秒回选手", "爱撒娇",
        "醋坛子", "小吃货", "安静的人", "有点毒舌"
    ]

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    addCard
                    listCard
                    suggestionCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("个性标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .aevisScreen("个性标签")
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("加一个")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("比如：嘴硬心软", text: $draft)
                    .font(.aevis(15))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .onSubmit { add() }
                Button {
                    add()
                } label: {
                    Text("贴上去")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(trimmedDraft.isEmpty ? accent.opacity(0.4) : accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("已经贴上的")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !tags.isEmpty {
                    Text("\(tags.count) 个")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if tags.isEmpty {
                Text("还没有。贴几个，她的资料页上就会显示出来。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ForEach(Array(tags.enumerated()), id: \.offset) { pair in
                    tagRow(pair.element)
                }
                Color.clear.frame(height: 6)
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    private func tagRow(_ tag: String) -> some View {
        HStack(spacing: 10) {
            Text(tag)
                .font(.aevis(14.5))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button {
                remove(tag)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.aevis(15))
                    .foregroundStyle(Color.red.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("懒得想？点几个现成的")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Self.suggestions.prefix(4), id: \.self) { value in
                    chip(value)
                }
            }
            HStack(spacing: 8) {
                ForEach(Self.suggestions.suffix(4), id: \.self) { value in
                    chip(value)
                }
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func chip(_ value: String) -> some View {
        let on = tags.contains(value)
        return Button {
            if on { remove(value) } else { addTag(value) }
        } label: {
            Text(value)
                .font(.aevis(12.5))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(on ? accent : Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func add() {
        addTag(trimmedDraft)
        draft = ""
    }

    private func addTag(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var next = personaStore.persona.tags
        guard !next.contains(value) else { return }
        next.append(value)
        apply(next)
    }

    private func remove(_ tag: String) {
        var next = personaStore.persona.tags
        next.removeAll { $0 == tag }
        apply(next)
    }

    private func apply(_ next: [String]) {
        var persona = personaStore.persona
        persona.tags = next
        personaStore.persona = persona
    }
}

// MARK: - 她的歌单（2026-10-04）

/// 她的歌单 —— 她在你网易云里收藏的那些歌。
///
/// ⚠️ 这张歌单是**真的建在你自己的网易云账号里**的（`HerPlaylist` 那段注释），
///    所以**要先登录网易云**才看得到；没登录就照实说，别装作有。
struct HerPlaylistSheet: View {

    @ObservedObject private var personaStore = PersonaStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tracks: [MusicTrack] = []
    @State private var status: String?
    @State private var loading = false

    private var herName: String {
        let name = personaStore.persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "她" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if loading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else if let status {
                        Text(status)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    ForEach(tracks) { track in
                        trackRow(track)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("她的歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                await load()
            }
        }
        .aevisScreen("她的歌单")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(herName)的歌单")
                .font(.aevis(16, weight: .semibold))
                .foregroundStyle(.primary)
            Text("她在你的网易云里收藏的那些歌。遇到真心喜欢的，她会自己收进去。")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .aevisGlass(cornerRadius: 18)
    }

    private func trackRow(_ track: MusicTrack) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.aevis(14))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .aevisGlass(cornerRadius: 14)
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        guard NeteaseClient.shared.isLoggedIn else {
            status = "还没登录网易云 —— 去「发现 → 音乐」登录一次，就能看到她的歌单了。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let lists = try await NeteaseClient.shared.myPlaylists()
            let wanted = HerPlaylist.realName(for: personaStore.persona)
            guard let hers = lists.first(where: { $0.name == wanted }) else {
                tracks = []
                status = "她的歌单还是空的。她在聊天里收藏过歌之后，这里就会有。"
                return
            }
            let songs = try await NeteaseClient.shared.playlistDetail(hers.id)
            tracks = songs
            status = songs.isEmpty ? "这张歌单还是空的。" : nil
        } catch {
            status = error.localizedDescription
        }
    }
}

