import SwiftUI

/// 审计日志：谁在什么时候从哪台机器登录、谁在用、封了哪些 IP。
struct AuditView: View {
    @State private var seg = 0
    @State private var state: LoadState = .idle

    @State private var overview: [String: Any] = [:]
    @State private var logins: [LoginRow] = []
    @State private var activity: [[String: Any]] = []
    @State private var blocks: [BlockRow] = []

    @State private var onlyFail = false
    @State private var showBlock = false

    var body: some View {
        NavigationStack {
            List {
                if case .fail = state {
                    StateBanner(state: state) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }

                Section {
                    Picker("", selection: $seg) {
                        Text("概览").tag(0)
                        Text("登录记录").tag(1)
                        Text("活跃").tag(2)
                        Text("封禁").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                switch seg {
                case 0: overviewSection
                case 1: loginsSection
                case 2: activitySection
                default: blocksSection
                }
            }
            .navigationTitle("审计日志")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if seg == 3 {
                        Button { showBlock = true } label: { Image(systemName: "hand.raised") }
                    }
                }
            }
            .refreshable { await load() }
            // 切页签、或勾「只看失败」都要重拉
            .task(id: "\(seg)-\(onlyFail)") { await load() }
            .sheet(isPresented: $showBlock) {
                BlockIPView { Task { await load() } }
            }
        }
    }

    // MARK: 概览

    @ViewBuilder private var overviewSection: some View {
        let t = overview.dict("today")
        Section("今日") {
            KVRow(k: "登录成功", v: "\(t.i("logins_ok"))")
            KVRow(k: "登录失败", v: "\(t.i("logins_fail"))")
            KVRow(k: "活跃账号", v: "\(t.i("users"))")
            KVRow(k: "独立 IP", v: "\(t.i("ips"))")
            KVRow(k: "账号总数", v: "\(overview.i("users_total"))")
            KVRow(k: "当前在线", v: "\(overview.i("online"))")
        }
        let trend = overview.list("trend")
        if !trend.isEmpty {
            Section("近 7 天") {
                ForEach(Array(trend.enumerated()), id: \.offset) { _, r in
                    HStack {
                        Text(r.s("day")).font(.footnote.monospacedDigit())
                        Spacer()
                        Text("登录 \(r.i("logins"))").font(.caption).foregroundStyle(.secondary)
                        Text("账号 \(r.i("users"))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        let top = overview.list("top_today")
        if !top.isEmpty {
            Section("今日活跃 TOP") {
                ForEach(Array(top.enumerated()), id: \.offset) { _, r in
                    HStack {
                        Text(r.s("username")).font(.footnote)
                        Spacer()
                        Text("\(r.i("hits")) 次").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        Section {
            Text(overview.s("rate_limit_note")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: 登录记录

    @ViewBuilder private var loginsSection: some View {
        Section {
            Toggle("只看失败", isOn: $onlyFail)
        }
        if logins.isEmpty {
            Text("没有记录").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(logins) { r in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(r.ok ? .green : .red)
                    Text(r.username.isEmpty ? "—" : r.username)
                        .font(.footnote.weight(.medium))
                    Text(r.ip).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text(Fmt.time(r.ts)).font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(r.where_).font(.caption2).foregroundStyle(.secondary)
                    if !r.note.isEmpty {
                        Chip(text: r.note, tint: .orange)
                    }
                }
                if !r.ua.isEmpty {
                    Text(r.ua).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 活跃

    @ViewBuilder private var activitySection: some View {
        if activity.isEmpty {
            Text("没有活跃记录").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(Array(activity.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(r.s("username").isEmpty ? "—" : r.s("username"))
                        .font(.footnote.weight(.medium))
                    Spacer()
                    Text("\(r.i("hits")) 次").font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(r.s("ip")).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    let w = [r.s("region"), r.s("city")].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !w.isEmpty { Text(w).font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                    Text(Fmt.time(r.s("last_seen"))).font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 封禁

    @ViewBuilder private var blocksSection: some View {
        if blocks.isEmpty {
            Text("没有封禁的 IP").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(blocks) { b in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.ip).font(.footnote.monospaced().weight(.medium))
                    Text(b.reason).font(.caption2).foregroundStyle(.secondary)
                    Text("到期：\(b.untilLabel)").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("解封") {
                    Task { await unblock(b.ip) }
                }
                .font(.footnote)
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: 数据

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            overview = DemoData.audit
            logins = DemoData.logins
            activity = DemoData.activity
            blocks = DemoData.blocks.map { BlockRow(raw: $0) }
            state = .done
            return
        }
        do {
            switch seg {
            case 0:
                overview = try await API.shared.get("/api/audit/overview")
            case 1:
                let r = try await API.shared.get("/api/audit/logins",
                                                  query: ["limit": "100",
                                                          "ok": onlyFail ? "0" : "-1"])
                logins = r.list("rows").map { LoginRow(raw: $0) }
            case 2:
                let r = try await API.shared.get("/api/audit/activity", query: ["limit": "200"])
                activity = r.list("rows")
            default:
                let r = try await API.shared.get("/api/audit/blocks")
                blocks = r.list("blocks").map { BlockRow(raw: $0) }
            }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }

    private func unblock(_ ip: String) async {
        if AppConfig.isDemo {
            Toast.shared.show("演示模式：解封 \(ip)（没有真的改）")
            return
        }
        do {
            _ = try await API.shared.delete("/api/audit/blocks/\(ip)")
            Toast.shared.show("已解封 \(ip)")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? error.localizedDescription)
        }
    }
}

/// 手动封一个 IP。
struct BlockIPView: View {
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var reason = ""
    @State private var hours = ""
    @State private var busy = false
    @State private var msg = ""
    @State private var msgOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP（如 1.2.3.4）", text: $ip)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("原因（可空）", text: $reason)
                    TextField("封多少小时（留空 = 永久）", text: $hours)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("被封的 IP 访问任何接口都会被拒。解错了就在这里把它解封。")
                        .font(.caption2)
                }

                if !msg.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: msgOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(msgOK ? .green : .red)
                            Text(msg).font(.footnote)
                        }
                    }
                }

                Section {
                    Button {
                        Task { await go() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "正在提交…" : "封禁").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || ip.trimmingCharacters(in: .whitespaces).count < 3)
                }
            }
            .navigationTitle("封禁 IP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } }
            }
        }
    }

    private func go() async {
        if AppConfig.isDemo {
            msgOK = true; msg = "演示模式：已封禁 \(ip)（没有真的封）"
            return
        }
        busy = true
        msg = ""
        var body: [String: Any] = ["ip": ip.trimmingCharacters(in: .whitespaces)]
        let r0 = reason.trimmingCharacters(in: .whitespaces)
        if !r0.isEmpty { body["reason"] = r0 }
        if let h = Double(hours.trimmingCharacters(in: .whitespaces)), h > 0 { body["hours"] = h }
        do {
            let r = try await API.shared.post("/api/audit/blocks", body: body)
            msgOK = true
            msg = r.s("msg")
            onChanged()
        } catch {
            msgOK = false
            msg = (error as? APIError)?.message ?? error.localizedDescription
        }
        busy = false
    }
}
