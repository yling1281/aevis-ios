import SwiftUI

// MARK: - 数据

struct TicketCategory: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }
}

struct TicketBrief: Identifiable, Hashable {
    let id: Int
    let category: String
    let categoryLabel: String
    let title: String
    let status: String
    let statusLabel: String
    let createdAt: String
    let updatedAt: String

    var isClosed: Bool { status == "closed" }
}

struct TicketMessage: Identifiable, Hashable {
    let id: Int
    let role: String        // user / staff
    let body: String
    let createdAt: String
    var isMine: Bool { role == "user" }
}

// MARK: - 服务

/// 工单：用户提问题 → 客服在后台回 → 用户在这里接着聊。
///
/// 后端 `aevis_tickets` 走 **Bearer**（`auth_session` 那套 token），
/// 不是社交模块的 `X-Account` —— 工单绑的是账号本身，不是昵称键。
@MainActor
final class TicketService: ObservableObject {
    static let shared = TicketService()

    @Published private(set) var categories: [TicketCategory] = [
        .init(code: "account", label: "账号与登录"),
        .init(code: "payment", label: "充值与订单"),
        .init(code: "bug", label: "功能异常"),
        .init(code: "feature", label: "功能建议"),
        .init(code: "other", label: "其它"),
    ]
    @Published private(set) var items: [TicketBrief] = []
    @Published private(set) var loading = false

    private var base: String { AevisHosts.accountBase }

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) -> URLRequest? {
        let token = AppSettings.shared.accountToken
        guard !token.isEmpty, let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    func loadMeta() async {
        guard let req = request("/v1/tickets/meta"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let list = d["categories"] as? [[String: Any]] else { return }
        let parsed = list.compactMap { r -> TicketCategory? in
            guard let c = r["code"] as? String, let l = r["label"] as? String else { return nil }
            return TicketCategory(code: c, label: l)
        }
        if !parsed.isEmpty { categories = parsed }
    }

    func load() async {
        guard AppSettings.shared.accountToken.isEmpty == false else { items = []; return }
        loading = items.isEmpty
        defer { loading = false }
        guard let req = request("/v1/tickets?limit=50"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let rows = d["items"] as? [[String: Any]] else { return }
        items = rows.map { r in
            TicketBrief(
                id: r["id"] as? Int ?? 0,
                category: r["category"] as? String ?? "other",
                categoryLabel: r["categoryLabel"] as? String ?? "其它",
                title: r["title"] as? String ?? "",
                status: r["status"] as? String ?? "open",
                statusLabel: r["statusLabel"] as? String ?? "",
                createdAt: r["createdAt"] as? String ?? "",
                updatedAt: r["updatedAt"] as? String ?? ""
            )
        }
    }

    /// 返回 (是否成功, 提示)。
    func create(category: String, title: String, body: String) async -> (Bool, String) {
        guard let req = request("/v1/tickets", method: "POST",
                                body: ["category": category, "title": title, "body": body]) else {
            return (false, "先登录账号再提交")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "网络异常，稍后再试")
        }
        if (obj["code"] as? Int) == 200 { return (true, "已提交") }
        return (false, obj["msg"] as? String ?? "提交失败")
    }

    func detail(_ id: Int) async -> (TicketBrief?, [TicketMessage]) {
        guard let req = request("/v1/tickets/\(id)"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let t = d["ticket"] as? [String: Any] else { return (nil, []) }
        let brief = TicketBrief(
            id: t["id"] as? Int ?? id,
            category: t["category"] as? String ?? "other",
            categoryLabel: t["categoryLabel"] as? String ?? "其它",
            title: t["title"] as? String ?? "",
            status: t["status"] as? String ?? "open",
            statusLabel: t["statusLabel"] as? String ?? "",
            createdAt: t["createdAt"] as? String ?? "",
            updatedAt: t["updatedAt"] as? String ?? ""
        )
        let msgs = (d["messages"] as? [[String: Any]] ?? []).map {
            TicketMessage(id: $0["id"] as? Int ?? 0,
                          role: $0["role"] as? String ?? "user",
                          body: $0["body"] as? String ?? "",
                          createdAt: $0["createdAt"] as? String ?? "")
        }
        return (brief, msgs)
    }

    func reply(_ id: Int, body: String) async -> (Bool, String) {
        guard let req = request("/v1/tickets/\(id)/reply", method: "POST",
                                body: ["body": body]) else { return (false, "先登录账号") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "网络异常")
        }
        if (obj["code"] as? Int) == 200 { return (true, "已发送") }
        return (false, obj["msg"] as? String ?? "发送失败")
    }

    func close(_ id: Int) async -> (Bool, String) {
        guard let req = request("/v1/tickets/\(id)/close", method: "POST", body: [:]) else {
            return (false, "先登录账号")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "网络异常")
        }
        if (obj["code"] as? Int) == 200 { return (true, "已关闭") }
        return (false, obj["msg"] as? String ?? "关闭失败")
    }
}

// MARK: - 列表

/// 我的工单。
///
/// 用户 2026-11-01：「APP 里面的那个工单提交…你也没弄好」。
/// 之前后端 `/v1/tickets` 一直是通的，但 App 里**一个入口都没有**，
/// 等于用户提不了。这一页就是补的那个入口（「我」→ 帮助与反馈）。
struct TicketListView: View {
    @ObservedObject private var svc = TicketService.shared
    @State private var showNew = false
    @State private var openID: Int?

    private var signedIn: Bool { !AppSettings.shared.accountToken.isEmpty }

    var body: some View {
        Group {
            if !signedIn {
                needLogin
            } else if svc.loading && svc.items.isEmpty {
                VStack(spacing: 10) {
                    Spacer(); ProgressView(); Text("加载中…")
                        .font(.aevis(13)).foregroundStyle(.secondary); Spacer()
                }
            } else if svc.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "envelope.open")
                        .font(.aevis(30)).foregroundStyle(.tertiary)
                    Text("还没有工单").font(.aevis(13.5)).foregroundStyle(.secondary)
                    Text("有问题点右上角「新建」").font(.aevis(12)).foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(svc.items) { t in
                        Button { openID = t.id } label: { row(t) }
                            .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("帮助与反馈")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNew = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!signedIn)
            }
        }
        .sheet(isPresented: $showNew) {
            NavigationStack {
                TicketNewView { }
            }
        }
        .sheet(item: Binding(
            get: { openID.map(IdentifiedInt.init) },
            set: { openID = $0?.value }
        )) { boxed in
            NavigationStack { TicketDetailView(ticketID: boxed.value) }
        }
        .task {
            await svc.loadMeta()
            await svc.load()
        }
        .refreshable { await svc.load() }
    }

    private var needLogin: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.aevis(30)).foregroundStyle(.tertiary)
            Text("登录后才能提交工单").font(.aevis(13.5)).foregroundStyle(.secondary)
            Text("工单会跟你的账号绑定，方便查进度")
                .font(.aevis(12)).foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private func row(_ t: TicketBrief) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(t.title)
                        .font(.aevis(15, weight: .medium))
                        .lineLimit(1)
                    statusPill(t)
                }
                Text("\(t.categoryLabel) · \(t.updatedAt)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.aevis(12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func statusPill(_ t: TicketBrief) -> some View {
        let color: Color = t.status == "open" ? .orange
            : (t.status == "pending" ? .blue : .secondary)
        return Text(t.statusLabel)
            .font(.aevis(10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

/// `sheet(item:)` 只吃 Identifiable，Int 得包一层。
private struct IdentifiedInt: Identifiable {
    let value: Int
    var id: Int { value }
}

// MARK: - 新建

struct TicketNewView: View {
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var svc = TicketService.shared

    @State private var category = "bug"
    @State private var title = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("问题类型") {
                Picker("类型", selection: $category) {
                    ForEach(svc.categories) { c in
                        Text(c.label).tag(c.code)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("标题") {
                TextField("一句话说清问题", text: $title)
                    .textInputAutocapitalization(.never)
            }
            Section("详细描述") {
                TextEditor(text: $bodyText)
                    .frame(minHeight: 140)
                    .font(.aevis(14))
            }
            if let error {
                Section { Text(error).font(.aevis(12.5)).foregroundStyle(.red) }
            }
            Section {
                Text("提交后客服会在后台看到；回复会出现在「帮助与反馈」里，不会漏。")
                    .font(.aevis(12)).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("新建工单")
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
                .disabled(sending || title.trimmingCharacters(in: .whitespaces).isEmpty
                          || bodyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() async {
        sending = true
        defer { sending = false }
        error = nil
        let (ok, msg) = await svc.create(
            category: category,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if ok {
            await svc.load()
            onDone()
            dismiss()
        } else {
            error = msg
        }
    }
}

// MARK: - 详情

struct TicketDetailView: View {
    let ticketID: Int

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var svc = TicketService.shared

    @State private var ticket: TicketBrief?
    @State private var messages: [TicketMessage] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let t = ticket {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t.title).font(.aevis(16, weight: .semibold))
                            Text("\(t.categoryLabel) · 开单 \(t.createdAt)")
                                .font(.aevis(11.5)).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    ForEach(messages) { m in
                        HStack {
                            if m.isMine { Spacer(minLength: 40) }
                            VStack(alignment: m.isMine ? .trailing : .leading, spacing: 4) {
                                Text(m.body)
                                    .font(.aevis(14))
                                    .foregroundStyle(m.isMine ? Color.white : Color.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(m.isMine
                                                  ? AppSettings.shared.accentColor
                                                  : Color(.secondarySystemGroupedBackground))
                                    )
                                Text(m.isMine ? m.createdAt : "客服 · \(m.createdAt)")
                                    .font(.aevis(10.5)).foregroundStyle(.tertiary)
                            }
                            if !m.isMine { Spacer(minLength: 40) }
                        }
                    }
                }
                .padding(14)
            }

            if ticket?.isClosed == true {
                Text("工单已关闭，如需继续请新建一单")
                    .font(.aevis(12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.regularMaterial)
            } else {
                HStack(spacing: 8) {
                    TextField("补充说明…", text: $draft, axis: .vertical)
                        .font(.aevis(14))
                        .lineLimit(1...4)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "paperplane.fill").font(.aevis(15)) }
                    }
                    .disabled(sending || draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }

            if let note {
                Text(note).font(.aevis(11.5)).foregroundStyle(.tertiary).padding(.bottom, 6)
            }
        }
        .navigationTitle("工单 #\(ticketID)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
            if ticket?.isClosed != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("结束工单") {
                        Task {
                            let (ok, msg) = await svc.close(ticketID)
                            note = msg
                            if ok { await reload() }
                        }
                    }
                    .font(.aevis(13))
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        let (t, m) = await svc.detail(ticketID)
        ticket = t
        messages = m
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true
        defer { sending = false }
        let (ok, msg) = await svc.reply(ticketID, body: text)
        note = ok ? nil : msg
        if ok {
            draft = ""
            await reload()
            await svc.load()
        }
    }
}
