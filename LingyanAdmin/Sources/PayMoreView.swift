import SwiftUI

/// 「更多」里能下钻的那几张表。用一个枚举描述「标题 + 接口 + 怎么变成一行」，
/// 这样不必为每张表写一个几乎一样的 View。
///
/// ⚠️ 枚举 case 名故意用小写（`notifyLogs` 这种）—— 本地静态自检
///    （`_ios/check_swift.py` 第 5 条）会把 `PayListKind.notifyLogs`
///    跟类型体里声明的成员对照，case 名会被当成成员收进来，写得规范就行。
enum PayListKind: String, CaseIterable, Identifiable {
    case notifyLogs
    case notifyInbox
    case pools
    case keys
    case users
    case tickets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifyLogs: return "发货回调日志"
        case .notifyInbox: return "收到的回调"
        case .pools: return "轮询池"
        case .keys: return "对外密钥"
        case .users: return "后台账号"
        case .tickets: return "工单"
        }
    }

    var icon: String {
        switch self {
        case .notifyLogs: return "paperplane"
        case .notifyInbox: return "tray.and.arrow.down"
        case .pools: return "arrow.triangle.2.circlepath"
        case .keys: return "key"
        case .users: return "person.2"
        case .tickets: return "bubble.left.and.bubble.right"
        }
    }

    var note: String {
        switch self {
        case .notifyLogs: return "每次给商户发回调的结果（HTTP 码 / 返回体）"
        case .notifyInbox: return "别人回调我们的记录（签名对不对）"
        case .pools: return "出码时按池子轮询挑通道"
        case .keys: return "给第三方用的接入密钥（拿码 / 验证 / 上传）"
        case .users: return "能登这个后台的账号"
        case .tickets: return "给买家/自己记的问题单"
        }
    }

    var path: String {
        switch self {
        case .notifyLogs: return "/api/notify-logs"
        case .notifyInbox: return "/api/notify-inbox"
        case .pools: return "/api/pools"
        case .keys: return "/api/keys"
        case .users: return "/api/users"
        case .tickets: return "/api/tickets"
        }
    }

    func demoItems() -> [[String: Any]] {
        switch self {
        case .notifyLogs: return PayDemo.notifyLogs
        case .notifyInbox: return PayDemo.notifyInbox
        case .pools: return PayDemo.pools
        case .keys: return PayDemo.keys
        case .users: return PayDemo.users
        case .tickets: return PayDemo.tickets
        }
    }

    func row(_ r: [String: Any]) -> PayRow {
        switch self {
        case .notifyLogs:
            let ok = r.i("ok")
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("order_no"),
                sub: Fmt.time(r.s("created_at")),
                right: ok == 1 ? "成功" : "失败",
                tone: ok == 1 ? 1 : 3,
                chip: "HTTP \(r.i("http_code"))",
                chipTint: ok == 1 ? .green : .red,
                detail: [
                    ("订单号", r.s("order_no")),
                    ("回调地址", r.s("url")),
                    ("HTTP 码", "\(r.i("http_code"))"),
                    ("发出的内容", r.s("req_body")),
                    ("对方返回", r.s("resp_body")),
                    ("时间", r.s("created_at")),
                ]
            )
        case .notifyInbox:
            let ok = r.i("sign_ok") == 1
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("order_no"),
                sub: "签名 " + (ok ? "对" : "不对") + " · 来自 " + r.s("remote"),
                right: Fmt.money(r.d("amount")),
                tone: ok ? 1 : 3,
                chip: ok ? "签名对" : "签名不对",
                chipTint: ok ? .green : .red,
                detail: [
                    ("订单号", r.s("order_no")),
                    ("商户单号", r.s("merchant_no")),
                    ("金额", Fmt.money(r.d("amount"))),
                    ("签名", r.s("sign")),
                    ("原文", r.s("body")),
                    ("来源", r.s("remote")),
                    ("时间", r.s("created_at")),
                ]
            )
        case .pools:
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("name"),
                sub: payTypeText(r.s("pay_type")) + " · 策略 " + r.s("strategy")
                     + " · 通道 " + r.s("channel_ids"),
                right: r.b("enabled") ? "启用" : "停用",
                tone: r.b("enabled") ? 1 : 3,
                detail: [
                    ("名称", r.s("name")),
                    ("支付方式", payTypeText(r.s("pay_type"))),
                    ("策略", r.s("strategy")),
                    ("通道 id", r.s("channel_ids")),
                    ("启用", r.b("enabled") ? "是" : "否"),
                    ("建立时间", r.s("created_at")),
                ]
            )
        case .keys:
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("name"),
                sub: r.s("last_used").isEmpty ? "没用过" : "最后使用 " + r.s("last_used"),
                right: r.b("enabled") ? "启用" : "停用",
                tone: r.b("enabled") ? 1 : 3,
                detail: [
                    ("名称", r.s("name")),
                    ("密钥", r.s("key")),
                    ("启用", r.b("enabled") ? "是" : "否"),
                    ("建立时间", r.s("created_at")),
                    ("最后使用", r.s("last_used")),
                ]
            )
        case .users:
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("username"),
                sub: "建立 " + r.s("created_at"),
                right: r.s("role"),
                tone: 0,
                chip: r.s("role"),
                chipTint: .blue,
                detail: [
                    ("账号", r.s("username")),
                    ("角色", r.s("role")),
                    ("建立时间", r.s("created_at")),
                    ("最后登录", r.s("last_login")),
                ]
            )
        case .tickets:
            let st = r.s("status")
            return PayRow(
                id: "\(r.i("id"))",
                title: r.s("title"),
                sub: r.s("content"),
                right: st == "open" ? "待处理" : "已回",
                tone: st == "open" ? 2 : 1,
                chip: st == "open" ? "待处理" : "已回复",
                chipTint: st == "open" ? .orange : .green,
                detail: [
                    ("单号", r.s("no")),
                    ("标题", r.s("title")),
                    ("内容", r.s("content")),
                    ("回复", r.s("reply")),
                    ("状态", st),
                    ("建立时间", r.s("created_at")),
                ]
            )
        }
    }
}

/// 码支付 · 更多。把剩下几张表都收在这里，避免 TabView 超过 5 个页签。
struct PayMoreView: View {
    @ObservedObject private var cfg = PayConfig.shared

    @State private var showSettings = false
    @State private var showSignOut = false

    /// 单独抽出来、并显式声明 `[PayListKind]`。
    /// 直接写 `ForEach([PayListKind.notifyLogs, .notifyInbox, …])` 也行，
    /// 但数组字面量靠首元素去推断元素类型这种写法偶尔会闹脾气，不值得省这几个字。
    private var kinds: [PayListKind] {
        [.notifyLogs, .notifyInbox, .pools, .keys, .users, .tickets]
    }

    private var commit: String {
        (Bundle.main.object(forInfoDictionaryKey: "LingyanCommit") as? String) ?? ""
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(kinds) { k in
                        NavigationLink {
                            PayListPage(kind: k)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(k.title)
                                    Text(k.note).font(.caption2).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: k.icon)
                            }
                        }
                    }
                } header: {
                    Text("码支付后台")
                }

                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label("支付设置", systemImage: "gearshape")
                    }
                }

                Section {
                    KVRow(k: "账号", v: cfg.username)
                    KVRow(k: "服务器", v: cfg.baseURL, mono: true)
                    KVRow(k: "App", v: "零砚后台 iOS（素材 + 码支付）")
                    KVRow(k: "提交", v: commit.isEmpty ? "—" : String(commit.prefix(8)), mono: true)
                } header: {
                    Text("当前登录")
                }

                Section {
                    Button(role: .destructive) {
                        showSignOut = true
                    } label: {
                        Label("退出码支付登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } footer: {
                    Text("只退出「码支付」这一侧，素材后台的登录不受影响。")
                        .font(.caption2)
                }
            }
            .navigationTitle("更多")
            .sheet(isPresented: $showSettings) {
                NavigationStack { PaySettingsView() }
            }
            .confirmationDialog("确定退出码支付登录？", isPresented: $showSignOut, titleVisibility: .visible) {
                Button("退出登录", role: .destructive) { cfg.signOut() }
                Button("取消", role: .cancel) { }
            }
        }
    }
}

/// 一张通用表：`GET kind.path` → 列表 → 点进去看全部字段。
struct PayListPage: View {
    let kind: PayListKind

    @State private var state: LoadState = .idle
    @State private var rows: [PayRow] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StateBanner(state: state) { Task { await load() } }
                if rows.isEmpty && !state.isLoading {
                    Text("没有数据").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    NavigationLink {
                        PayDetailView(row: row)
                    } label: {
                        PayRowCell(row: row)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(kind.title)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            rows = kind.demoItems().map { kind.row($0) }
            state = .done
            return
        }
        do {
            let r = try await PayAPI.shared.get(kind.path)
            rows = r.list("items").map { kind.row($0) }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}

/// 支付设置：只读展示（改设置在电脑上做，手机上误触改坏线上参数的风险不值得）。
struct PaySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var state: LoadState = .idle
    @State private var settings: [String: Any] = [:]

    private var keys: [String] { settings.keys.sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                StateBanner(state: state) { Task { await load() } }
                PayCard(title: "共 \(keys.count) 项") {
                    if keys.isEmpty {
                        Text(state.isLoading ? "正在加载…" : "没有设置项")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(keys, id: \.self) { k in
                        KVRow(k: k, v: "\(settings[k] ?? "")", mono: true)
                    }
                }
                Text("手机上只读。要改这些参数请用电脑登 \(PayConfig.shared.baseURL)。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("支付设置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            settings = PayDemo.settings
            state = .done
            return
        }
        do {
            let r = try await PayAPI.shared.get("/api/settings")
            settings = r.dict("settings")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }
}
