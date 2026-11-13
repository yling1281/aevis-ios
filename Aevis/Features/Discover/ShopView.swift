import SwiftUI
#if canImport(UIKit)
import UIKit
import AVFoundation
#endif

// MARK: - 云端表情包

/// 商城里的一整套表情。
///
/// 2026-11-13 用户：「表情包的话其实就是一个商城…图床也不要，就是我们给它下表情包的那些包」——
/// 所以这里只认**整包**（后端 `/v1/emoji/list` 返回的就是 `{id, cover_url, count, items[]}`），
/// 不做单张图上传，也不做图床。
struct ShopEmojiPack: Identifiable, Hashable {
    let id: String
    let intro: String
    let count: Int
    let coverURL: String
    let items: [String]
    let createdAt: String

    init?(dict: [String: Any]) {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        intro = dict["intro"] as? String ?? ""
        let raw = dict["items"] as? [String] ?? []
        items = raw.map { ShopEmojiPack.absolute($0) }
        count = (dict["count"] as? Int) ?? raw.count
        coverURL = ShopEmojiPack.absolute(dict["cover_url"] as? String ?? "")
        createdAt = dict["created_at"] as? String ?? ""
    }

    static func absolute(_ u: String) -> String {
        let v = u.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        return v.hasPrefix("http") ? v : (AevisHosts.accountBase + v)
    }
}

// MARK: - 音色

/// 系统 TTS 的一个音色。
///
/// 后端没有音色表，直接用 `AVSpeechSynthesisVoice` 里的中文音色 ——
/// 这是**本机现成**的，不额外占服务器，也不会因为网络卡。
struct ShopVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let lang: String
    let premium: Bool

    /// MiniMax 系统音色（与后端 `aevis_tts.VOICES` 同一份清单，改一处要同步）。
    static let minimax: [ShopVoice] = [
        .init(id: "female-shaonv", name: "少女", lang: "zh-CN", premium: true),
        .init(id: "female-yujie", name: "御姐", lang: "zh-CN", premium: true),
        .init(id: "female-chengshu", name: "成熟女声", lang: "zh-CN", premium: true),
        .init(id: "female-tianmei", name: "甜美女声", lang: "zh-CN", premium: true),
        .init(id: "male-qn-qingse", name: "青涩青年", lang: "zh-CN", premium: true),
        .init(id: "male-qn-jingying", name: "精英青年", lang: "zh-CN", premium: true),
        .init(id: "male-qn-badao", name: "霸道青年", lang: "zh-CN", premium: true),
        .init(id: "male-qn-daxuesheng", name: "大学生", lang: "zh-CN", premium: true),
        .init(id: "presenter_male", name: "男主持", lang: "zh-CN", premium: true),
        .init(id: "presenter_female", name: "女主持", lang: "zh-CN", premium: true),
        .init(id: "audiobook_male_1", name: "男声书", lang: "zh-CN", premium: true),
        .init(id: "audiobook_female_1", name: "女声书", lang: "zh-CN", premium: true),
    ]
}

// MARK: - 商城

/// 商城：人设 / 表情包 / 音色。
///
/// 2026-11-13 用户：「直接弄一个商城，里面是人设和表情包还有音色，
/// 然后那个表情包直接去掉」—— 原来的「人设广场」升级成商城，
/// 独立的「表情包」入口不再单独存在，全部收进这里。
struct ShopView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var personaStore = PersonaPlazaStore.shared
    @ObservedObject private var settings = AppSettings.shared

    enum Tab: String, CaseIterable {
        case persona = "人设"
        case emoji = "表情包"
        case voice = "音色"
    }

    @State private var tab: Tab = .persona
    @State private var keyword = ""
    @State private var packs: [ShopEmojiPack] = []
    @State private var packsLoading = false
    @State private var packsError: String?

    @State private var voices: [ShopVoice] = []
    @State private var previewing: String = ""

    @State private var openPack: ShopEmojiPack?

    /// 试听用的合成器。用 State 存引用类型不理想，但这里只需要它活到页面结束。
    /// 试听走服务端的**缓存 mp3**（每个音色只合成一次，谁点都不再花钱）。
    @State private var previewPlayer: AVPlayer?

    var body: some View {
        // ⚠️ 以前这里**没有 NavigationStack**，人设格子用的是 NavigationLink ——
        //    没有导航栈的时候 NavigationLink 就是个纯装饰，点了毫无反应
        //    （2026-11-13 用户：「人设广场点不进去」）。套上它才真的能进详情。
        NavigationStack {
            VStack(spacing: 0) {
                header
                searchBar
                segmented
                Divider().opacity(0.4)
                content
            }
            .background(V2.background.ignoresSafeArea())
            // 根页用自定义头（带「人设 · 表情包 · 音色」副标题），把系统空导航栏藏掉；
            // 推进去的人设详情会自己把导航栏显示出来（带系统返回键）。
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if personaStore.rows.isEmpty { await personaStore.load() }
                await loadPacks()
                loadVoices()
            }
            .sheet(item: $openPack) { pack in
                ShopPackDetail(pack: pack)
            }
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                dismiss()
            } label: {
                // 2026-11-13 用户：「返回键有点怪怪的」——
                // 原来是一个 36×36 的圆底 + 一根箭头，跟系统返回键不是一个东西，
                // 而且圆底和左边的 18pt 留白没对齐。改成 iOS 原生的「‹ 返回」。
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.aevis(16, weight: .semibold))
                    Text("返回").font(.aevis(16))
                }
                .foregroundStyle(V2.accent)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 1) {
                Text("商城").font(.aevis(22, weight: .bold))
                Text("人设 · 表情包 · 音色").font(.aevis(11.5)).foregroundStyle(V2.dim(0.42))
            }
            Spacer()
        }
        .padding(.horizontal, V2.gutter)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.aevis(13))
                .foregroundStyle(V2.dim(0.34))
            TextField(placeholder, text: $keyword)
                .font(.aevis(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.aevis(14))
                        .foregroundStyle(V2.dim(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(V2.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(V2.stroke, lineWidth: 1)
        )
        .padding(.horizontal, V2.gutter)
    }

    private var placeholder: String {
        switch tab {
        case .persona: return "搜名字、身份、性格"
        case .emoji: return "搜表情包"
        case .voice: return "搜音色"
        }
    }

    // MARK: 分段

    private var segmented: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = t }
                    keyword = ""
                } label: {
                    Text(t.rawValue)
                        .font(.aevis(13.5, weight: tab == t ? .semibold : .regular))
                        .foregroundStyle(tab == t ? .white : V2.dim(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(tab == t ? V2.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(V2.well, in: Capsule())
        .padding(.horizontal, V2.gutter)
        .padding(.vertical, 12)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .persona: personaGrid
        case .emoji: emojiList
        case .voice: voiceList
        }
    }

    // MARK: 人设

    private var filteredPersonas: [PlazaPersona] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return personaStore.rows }
        return personaStore.rows.filter {
            $0.name.lowercased().contains(k)
                || $0.identity.lowercased().contains(k)
                || $0.personality.lowercased().contains(k)
                || $0.tagline.lowercased().contains(k)
        }
    }

    @ViewBuilder
    private var personaGrid: some View {
        if personaStore.loading && personaStore.rows.isEmpty {
            loadingBlock("正在读人设…")
        } else if filteredPersonas.isEmpty {
            emptyBlock(keyword.isEmpty ? "广场还空着" : "没找到「\(keyword)」")
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 14) {
                    ForEach(filteredPersonas) { p in
                        NavigationLink {
                            ShopPersonaDetail(persona: p)
                        } label: {
                            ShopPersonaCard(persona: p)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, V2.gutter)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    // MARK: 表情包

    @ViewBuilder
    private var emojiList: some View {
        if packsLoading && packs.isEmpty {
            loadingBlock("正在读表情包…")
        } else if let e = packsError {
            emptyBlock(e)
        } else if filteredPacks.isEmpty {
            emptyBlock("还没有表情包")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredPacks) { pack in
                        Button {
                            openPack = pack
                        } label: {
                            ShopPackCard(pack: pack)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, V2.gutter)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    private var filteredPacks: [ShopEmojiPack] {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !k.isEmpty else { return packs }
        return packs.filter { $0.intro.lowercased().contains(k) || $0.id.lowercased().contains(k) }
    }

    // MARK: 音色

    @ViewBuilder
    private var voiceList: some View {
        if voices.isEmpty {
            emptyBlock("这台设备没有可用的中文音色")
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(voices) { v in
                        ShopVoiceRow(
                            voice: v,
                            selected: settings.ttsVoice == v.id,
                            previewing: previewing == v.id,
                            onPreview: { preview(v) },
                            onSelect: { settings.ttsVoice = v.id }
                        )
                    }
                }
                .padding(.horizontal, V2.gutter)
                .padding(.top, 14)
                .padding(.bottom, 30)
            }
        }
    }

    /// 试听：放服务端缓存的 mp3。
    ///
    /// 2026-11-13 用户：「音色不用原生的了，用 MiniMax」「试听别花我们的余额」。
    /// 服务端每个音色只合成一次并落盘，之后所有人试听都是读文件 —— 零调用、零花费。
    private func preview(_ v: ShopVoice) {
        previewPlayer?.pause()
        previewing = v.id
        guard let url = URL(string:
            "https://aevis.cn/prod-api/aevis/v1/tts/preview/\(v.id).mp3") else { return }
        let p = AVPlayer(url: url)
        previewPlayer = p
        p.play()
        // 这句试听文案大约 3 秒，留点余量把按钮态收回去
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if previewing == v.id { previewing = "" }
        }
    }

    // MARK: 占位

    private func loadingBlock(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.aevis(13)).foregroundStyle(V2.dim(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyBlock(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.aevis(28))
                .foregroundStyle(V2.dim(0.2))
            Text(text).font(.aevis(13)).foregroundStyle(V2.dim(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 取数

    private func loadPacks() async {
        packsLoading = true
        defer { packsLoading = false }
        let base = AevisHosts.accountBase
        guard let url = URL(string: base + "/v1/emoji/list") else { return }
        var req = URLRequest(url: url)
        let acc = AppSettings.shared.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !acc.isEmpty { req.setValue(acc, forHTTPHeaderField: "X-Account") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let rows = d["rows"] as? [[String: Any]] else {
            packsError = "表情包加载失败，下拉重试"
            return
        }
        packsError = nil
        packs = rows.compactMap { ShopEmojiPack(dict: $0) }
    }

    /// 音色清单：MiniMax 的系统音色（和后端 `aevis_tts.VOICES` 一一对应）。
    ///
    /// 以前这里拉的是**系统** AVSpeechSynthesisVoice —— 那些音色导不出音频文件、
    /// 发语音消息也用不了；用户充值 MiniMax 之后统一换成它家的。
    private func loadVoices() {
        voices = ShopVoice.minimax
    }
}

// MARK: - 音色友好名

extension ShopVoice {
    /// 系统给的音色名是 `Tingting` / `Sinji` 这种拼音，翻成人能认的。
    static func friendly(_ raw: String) -> String {
        let map: [String: String] = [
            "Tingting": "婷婷（女）",
            "Sinji": "善怡（女）",
            "Meijia": "美佳（女）",
            "Yu-shu": "雨舒（女）",
            "Li-mu": "丽慕（女）",
            "Bo": "博（男）",
            "Lanlan": "兰兰（女）",
            "Xiaoxiao": "晓晓（女）",
            "Yunxi": "云希（男）",
            "Yunyang": "云扬（男）",
            "Xiaoyi": "晓伊（女）",
            "Yunjian": "云健（男）",
            "Yunxia": "云夏（男）",
            "Yunfeng": "云枫（男）"
        ]
        return map[raw] ?? raw
    }
}

// MARK: - 人设卡

struct ShopPersonaCard: View {
    let persona: PlazaPersona

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(V2.well)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay {
                        if let u = URL(string: persona.coverURL.isEmpty ? persona.avatarURL : persona.coverURL),
                           !persona.coverURL.isEmpty || !persona.avatarURL.isEmpty {
                            AsyncImage(url: u) { img in
                                img.resizable().scaledToFill()
                            } placeholder: {
                                Color.clear
                            }
                        } else {
                            Image(systemName: "person.fill")
                                .font(.aevis(30))
                                .foregroundStyle(V2.dim(0.18))
                        }
                    }
                    .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                               startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.name)
                        .font(.aevis(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !persona.identity.isEmpty {
                        Text(persona.identity)
                            .font(.aevis(10.5))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.aevis(9))
                Text("\(persona.adoptCount)").font(.aevis(10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(V2.dim(0.38))
            .padding(.top, 8)
            // 跟封面里那个名字的左边缘对齐（那里是 10）——
            // 原来这里是 2，两行字左边缘差 8pt，看着就是「没对齐」。
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
        }
        // 空白处也要能点进去 —— 否则只有图片/文字那几条线响应
        .contentShape(Rectangle())
    }
}

// MARK: - 表情包卡

struct ShopPackCard: View {
    let pack: ShopEmojiPack

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(V2.well)
                    .frame(width: 72, height: 72)
                if let u = URL(string: pack.coverURL) {
                    AsyncImage(url: u) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(pack.intro.isEmpty ? pack.id : pack.intro)
                    .font(.aevis(14.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(pack.count) 张")
                    .font(.aevis(11.5))
                    .foregroundStyle(V2.dim(0.42))
            }

            Spacer(minLength: 0)

            Text("查看")
                .font(.aevis(11.5, weight: .medium))
                .foregroundStyle(V2.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(V2.soft(0.12)))
        }
        .padding(12)
        .background(V2.card, in: RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: V2.rowRadius, style: .continuous)
                .stroke(V2.stroke, lineWidth: 1)
        )
    }
}

// MARK: - 音色行

struct ShopVoiceRow: View {
    let voice: ShopVoice
    let selected: Bool
    let previewing: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPreview) {
                Image(systemName: previewing ? "waveform" : "play.circle.fill")
                    .font(.aevis(20))
                    .foregroundStyle(V2.accent)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(voice.name).font(.aevis(14.5, weight: .medium))
                    if voice.premium {
                        Text("高清")
                            .font(.aevis(9.5))
                            .foregroundStyle(V2.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(V2.soft(0.14)))
                    }
                }
                Text(voice.lang).font(.aevis(11)).foregroundStyle(V2.dim(0.4))
            }

            Spacer(minLength: 0)

            Button(action: onSelect) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.aevis(20))
                    .foregroundStyle(selected ? V2.accent : V2.dim(0.22))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(V2.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? V2.soft(0.4) : V2.stroke, lineWidth: 1)
        )
    }
}

// MARK: - 人设详情

struct ShopPersonaDetail: View {
    let persona: PlazaPersona
    @Environment(\.dismiss) private var dismiss
    @State private var added = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(V2.well)
                        .frame(height: 300)
                        .overlay {
                            if let u = URL(string: persona.coverURL.isEmpty ? persona.avatarURL : persona.coverURL) {
                                AsyncImage(url: u) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Color.clear }
                            }
                        }
                        .clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                   startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(persona.name)
                            .font(.aevis(24, weight: .bold))
                            .foregroundStyle(.white)
                        if !persona.tagline.isEmpty {
                            Text(persona.tagline)
                                .font(.aevis(12.5))
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    .padding(16)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                if !persona.personality.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("性格").font(.aevis(12, weight: .semibold)).foregroundStyle(V2.dim(0.5))
                        Text(persona.personality)
                            .font(.aevis(14))
                            .lineSpacing(3)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(V2.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                HStack(spacing: 10) {
                    Button {
                        guard !added else { return }
                        var p = persona.toPersona()
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { return }
                        let id = PersonaStore.shared.add(p)
                        PersonaStore.shared.select(id)
                        added = true
                        Task { await persona.applyAvatar(to: id) }
                    } label: {
                        Text(added ? "已加进通讯录" : "加为好友")
                            .font(.aevis(15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(added ? Color.gray.opacity(0.5) : V2.accent)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, V2.gutter)
            .padding(.bottom, 30)
        }
        .background(V2.background.ignoresSafeArea())
        // 根页把导航栏藏了，推进来的详情要显式打开 —— 否则没有系统返回键。
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("人设详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 包详情（九宫格）

struct ShopPackDetail: View {
    let pack: ShopEmojiPack
    @Environment(\.dismiss) private var dismiss

    private let cols = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(pack.items, id: \.self) { u in
                        Button {
                            sendToChat(u)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(V2.well)
                                if let url = URL(string: u) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.clear }
                                }
                            }
                            .frame(height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(V2.gutter)
            }
            .background(V2.background.ignoresSafeArea())
            .navigationTitle(pack.intro.isEmpty ? "表情包" : pack.intro)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 点一张 → 直接发到当前聊天。
    ///
    /// 商城里没有「上传」，也没有图床 —— 只是把包里已有的图发出去。
    private func sendToChat(_ url: String) {
        NotificationCenter.default.post(name: .aevisSendSticker,
                                        object: nil,
                                        userInfo: ["url": url])
        dismiss()
    }
}

extension Notification.Name {
    /// 商城点表情 → 发到当前会话。
    static let aevisSendSticker = Notification.Name("aevis.send.sticker")
}

// MARK: - 发现页的商城入口

/// 发现页第一屏那张「商城」卡。
///
/// 2026-11-13 用户：「发现页的话就是你全部重组」「直接弄一个商城，
/// 里面是人设和表情包还有音色，然后那个表情包直接去掉」——
/// 所以原来的「人设广场横滑条 + 表情包入口」合并成这一张卡。
struct ShopEntryCard: View {
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(V2.soft(0.14))
                        .frame(width: 46, height: 46)
                    Image(systemName: "bag.fill")
                        .font(.aevis(19))
                        .foregroundStyle(V2.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("商城")
                        .font(.aevis(V2.body, weight: .semibold))
                    Text("人设 · 表情包 · 音色")
                        .font(.aevis(V2.tiny))
                        .foregroundStyle(V2.dim(0.45))
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.aevis(12))
                    .foregroundStyle(V2.dim(0.28))
            }
            .padding(.horizontal, V2.gutter)
            .padding(.vertical, 14)
            .background(
                V2.card,
                in: RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                    .stroke(V2.stroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, V2.gutter)
    }
}
