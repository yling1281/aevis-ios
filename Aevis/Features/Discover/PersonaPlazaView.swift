import SwiftUI

// MARK: - 模型

/// 人设广场里的一个人设。
///
/// 后端 `/v1/psquare/list` → `persona_public` 表（`status='published'`）。
/// 用户自己上传的走 `/v1/psquare/publish`，先落 `pending`（AI 审 → 上架 → 邮件提醒人工复审）。
struct PlazaPersona: Identifiable, Hashable {
    let id: String
    let name: String
    let gender: String
    let age: String
    let identity: String
    let relation: String
    let personality: String
    let tagline: String
    let avatarURL: String
    let adoptCount: Int

    init(dict: [String: Any]) {
        id = (dict["id"] as? String) ?? UUID().uuidString
        name = dict["name"] as? String ?? ""
        gender = dict["gender"] as? String ?? ""
        age = dict["age"] as? String ?? ""
        identity = dict["identity"] as? String ?? ""
        relation = dict["relation"] as? String ?? ""
        personality = dict["personality"] as? String ?? ""
        tagline = dict["tagline"] as? String ?? ""
        avatarURL = dict["avatar_url"] as? String ?? ""
        adoptCount = dict["adopt_count"] as? Int ?? 0
    }

    /// 转成本地 `Persona`（「加为好友」用）。
    func toPersona() -> Persona {
        var p = Persona()
        p.name = name
        switch gender {
        case "female", "女", "她": p.gender = .female
        case "male", "男", "他": p.gender = .male
        case "genderless", "无性别": p.gender = .genderless
        default: p.gender = .unspecified
        }
        p.callUser = identity
        p.relationship = relation
        p.personality = personality
        p.speakingStyle = tagline
        return p
    }

    var subtitle: String {
        [relation.isEmpty ? nil : relation,
         age.isEmpty ? nil : age + " 岁",
         identity.isEmpty ? nil : "叫你" + identity].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - 服务

@MainActor
final class PersonaPlazaStore: ObservableObject {
    static let shared = PersonaPlazaStore()

    @Published private(set) var rows: [PlazaPersona] = []
    @Published private(set) var loading = false
    @Published var error: String?

    private var base: String { AevisHosts.accountBase }
    private var account: String {
        AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func load() async {
        loading = rows.isEmpty
        defer { loading = false }
        guard let url = URL(string: base + "/v1/psquare/list") else { return }
        var req = URLRequest(url: url)
        if !account.isEmpty { req.setValue(account, forHTTPHeaderField: "X-Account") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let list = d["rows"] as? [[String: Any]] else {
            error = "广场加载失败，下拉再试"
            return
        }
        rows = list.map(PlazaPersona.init(dict:))
        error = nil
    }

    /// 上传一个自己的人设。返回 (成功, 提示)。
    func publish(name: String, gender: String, age: String, identity: String,
                 relation: String, personality: String, appearance: String,
                 tagline: String) async -> (Bool, String) {
        guard !account.isEmpty else { return (false, "先登录账号，才能上传") }
        guard let url = URL(string: base + "/v1/psquare/publish") else { return (false, "地址不对") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(account, forHTTPHeaderField: "X-Account")
        let body: [String: String] = [
            "name": name, "gender": gender, "age": age, "identity": identity,
            "relation": relation, "personality": personality,
            "appearance": appearance, "tagline": tagline,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "网络异常，稍后再试")
        }
        if (obj["code"] as? Int) == 0 {
            return (true, obj["msg"] as? String ?? "已提交，审核通过后上架")
        }
        return (false, obj["msg"] as? String ?? "提交失败")
    }
}

// MARK: - 头像

/// 没有头像时的占位：名字首字 + 按名字定的渐变色。
/// **不用随机色** —— 同一个名字每次进来颜色必须一样，否则列表会闪。
struct PlazaAvatar: View {
    let name: String
    let url: String
    var size: CGFloat = 52

    private var seed: Int {
        var h = 5381
        for u in name.unicodeScalars { h = (h &* 33) &+ Int(u.value) }
        return abs(h)
    }

    private var colors: [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.36, green: 0.71, blue: 0.66), Color(red: 0.20, green: 0.49, blue: 0.55)],
            [Color(red: 0.95, green: 0.62, blue: 0.50), Color(red: 0.84, green: 0.38, blue: 0.42)],
            [Color(red: 0.55, green: 0.60, blue: 0.88), Color(red: 0.36, green: 0.40, blue: 0.72)],
            [Color(red: 0.96, green: 0.78, blue: 0.45), Color(red: 0.87, green: 0.55, blue: 0.28)],
            [Color(red: 0.62, green: 0.80, blue: 0.55), Color(red: 0.35, green: 0.62, blue: 0.44)],
        ]
        return palettes[seed % palettes.count]
    }

    var body: some View {
        Group {
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(name.prefix(1)))
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - 发现页横滑条

/// 发现页顶部那条「人设广场」。
///
/// 用户 2026-11-01：「人社广场你要在发现页那里做一个人可以在那里刷」——
/// 所以不是一个藏在设置里的入口，而是**发现页第一屏就能横着刷**。
struct PersonaPlazaStrip: View {
    var onOpenAll: () -> Void
    var onUpload: () -> Void

    @ObservedObject private var store = PersonaPlazaStore.shared

    var body: some View {
        V2Card {
            HStack(spacing: 8) {
                V2IconBox("person.2.badge.plus", size: 32)
                Text("人设广场")
                    .font(.aevis(V2.body, weight: .semibold))
                Spacer(minLength: 6)
                Button {
                    onUpload()
                } label: {
                    Text("写一个")
                        .font(.aevis(V2.tiny, weight: .medium))
                        .foregroundStyle(V2.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(V2.soft(0.12)))
                }
                .buttonStyle(.plain)

                Button {
                    onOpenAll()
                } label: {
                    Text("全部")
                        .font(.aevis(V2.tiny))
                        .foregroundStyle(V2.dim(0.42))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, V2.gutter)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if store.rows.isEmpty {
                HStack(spacing: 8) {
                    if store.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        V2CatFace(size: 30, tint: V2.dim(0.22))
                    }
                    Text(store.loading ? "正在加载广场…" : "广场还空着，来当第一个")
                        .font(.aevis(12.5))
                        .foregroundStyle(V2.dim(0.42))
                }
                .padding(.horizontal, V2.gutter)
                .padding(.bottom, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(store.rows.prefix(12)) { p in
                            Button { onOpenAll() } label: {
                                card(p)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, V2.gutter)
                }
                .padding(.bottom, 16)
            }
        }
        .task { if store.rows.isEmpty { await store.load() } }
    }

    private func card(_ p: PlazaPersona) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PlazaAvatar(name: p.name, url: p.avatarURL, size: 58)
            Text(p.name)
                .font(.aevis(13.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(p.tagline.isEmpty ? p.subtitle : p.tagline)
                .font(.aevis(11))
                .foregroundStyle(V2.dim(0.45))
                .lineLimit(2)
                .frame(height: 28, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 104, alignment: .leading)
    }
}

// MARK: - 完整广场

struct PersonaPlazaView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PersonaPlazaStore.shared

    @State private var detail: PlazaPersona?
    @State private var showPublish = false
    @State private var toast: String?

    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.rows.isEmpty && !store.loading {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2")
                            .font(.aevis(30)).foregroundStyle(.tertiary)
                        Text("广场还空着").font(.aevis(13.5)).foregroundStyle(.secondary)
                        Button("写第一个人设") { showPublish = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: cols, spacing: 12) {
                        ForEach(store.rows) { p in
                            Button { detail = p } label: { tile(p) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                }
            }
            .refreshable { await store.load() }
            .background(V2.background.ignoresSafeArea())
            .navigationTitle("人设广场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPublish = true
                    } label: {
                        Label("写一个", systemImage: "square.and.pencil")
                            .font(.aevis(13))
                    }
                }
            }
            .sheet(item: $detail) { p in
                PlazaDetailView(persona: p, onUsed: { msg in toast = msg })
            }
            .sheet(isPresented: $showPublish) {
                PersonaPublishView { msg in
                    toast = msg
                    Task { await store.load() }
                }
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.aevis(13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 26)
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 2_400_000_000)
                            withAnimation { self.toast = nil }
                        }
                }
            }
            .task { await store.load() }
        }
    }

    private func tile(_ p: PlazaPersona) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            PlazaAvatar(name: p.name, url: p.avatarURL, size: 64)
            Text(p.name)
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !p.tagline.isEmpty {
                Text(p.tagline)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(height: 32, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(p.subtitle)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(height: 32, alignment: .top)
            }
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill").font(.aevis(9.5))
                Text("\(p.adoptCount)").font(.aevis(10.5))
            }
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(V2.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(V2.stroke, lineWidth: 0.5)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - 详情

struct PlazaDetailView: View {
    let persona: PlazaPersona
    var onUsed: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var added = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        PlazaAvatar(name: persona.name, url: persona.avatarURL, size: 76)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(persona.name).font(.aevis(20, weight: .semibold))
                            Text(persona.subtitle)
                                .font(.aevis(12.5)).foregroundStyle(.secondary)
                            Text("\(persona.adoptCount) 人用过")
                                .font(.aevis(11.5)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }

                    if !persona.tagline.isEmpty {
                        info("一句话", persona.tagline)
                    }
                    if !persona.personality.isEmpty {
                        info("性格", persona.personality)
                    }
                    if !persona.relation.isEmpty {
                        info("关系", persona.relation)
                    }

                    Button {
                        var p = persona.toPersona()
                        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { return }
                        // 加进通讯录并切过去 —— 之后就能直接聊。
                        let id = PersonaStore.shared.add(p)
                        PersonaStore.shared.select(id)
                        added = true
                        onUsed("已把「\(p.name)」加进通讯录")
                        dismiss()
                    } label: {
                        Label(added ? "已加入通讯录" : "加为好友，开始聊",
                              systemImage: added ? "checkmark.circle.fill" : "person.badge.plus")
                            .font(.aevis(15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(added)

                    Text("这是其他用户分享的人设。加进来之后，设定就归你了，可以随便改。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
            }
            .navigationTitle("人设详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(k).font(.aevis(11.5)).foregroundStyle(.tertiary)
            Text(v).font(.aevis(14)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - 上传

/// 自己写一个人设传上去。
///
/// 用户 2026-11-01：「也能在那里自己写一个上传」。
/// 提交后进 `pending`：AI 先审 → 通过先上架 → 同时邮件提醒站长人工复审。
struct PersonaPublishView: View {
    var onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PersonaPlazaStore.shared

    @State private var name = ""
    @State private var gender = "unspecified"
    @State private var age = ""
    @State private var identity = ""
    @State private var relation = "恋人"
    @State private var personality = ""
    @State private var appearance = ""
    @State private var tagline = ""
    @State private var sending = false
    @State private var error: String?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
        && !personality.trimmingCharacters(in: .whitespaces).isEmpty
        && !sending
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名字（必填）", text: $name)
                    Picker("性别", selection: $gender) {
                        Text("不设定").tag("unspecified")
                        Text("女").tag("female")
                        Text("男").tag("male")
                        Text("无性别").tag("genderless")
                    }
                    TextField("年龄，如 24（可留空）", text: $age)
                        .keyboardType(.numberPad)
                }
                Section("关系") {
                    TextField("ta 怎么称呼你", text: $identity)
                    TextField("你们是什么关系（恋人 / 朋友 / 同事…）", text: $relation)
                }
                Section("人设") {
                    TextEditor(text: $personality)
                        .frame(minHeight: 110)
                        .font(.aevis(14))
                        .overlay(alignment: .topLeading) {
                            if personality.isEmpty {
                                Text("性格、说话方式、习惯、口头禅…写得越具体，ta 越像那个人")
                                    .font(.aevis(13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                    TextField("外貌（可留空）", text: $appearance)
                }
                Section("广场上显示的一句话") {
                    TextField("如「嘴硬心软的医生」", text: $tagline)
                }
                if let error {
                    Section { Text(error).font(.aevis(12.5)).foregroundStyle(.red) }
                }
                Section {
                    Text("提交后先由 AI 审一遍：过了就会出现在广场，但先不进推荐位；工作室人工复核通过后才会推到前排。违规内容会被下架。")
                        .font(.aevis(11.5)).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("上传人设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) }
                        else { Text("提交").bold() }
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        error = nil
        let (ok, msg) = await store.publish(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            gender: gender, age: age,
            identity: identity.trimmingCharacters(in: .whitespacesAndNewlines),
            relation: relation.trimmingCharacters(in: .whitespacesAndNewlines),
            personality: personality.trimmingCharacters(in: .whitespacesAndNewlines),
            appearance: appearance.trimmingCharacters(in: .whitespacesAndNewlines),
            tagline: tagline.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if ok {
            onDone(msg)
            dismiss()
        } else {
            error = msg
        }
    }
}
