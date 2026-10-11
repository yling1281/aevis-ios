import SwiftUI

/// 码支付 · 通道。
///
/// 零砚最关心的一页：**哪条通道现在真的能收钱**。
/// 数据 `GET /api/channels`；探活 `POST /api/channels/probe`（跟出码时用的是**同一套**
/// 判活，所以不会出现「后台说在线、下单却降级了」）。
///
/// ⚠️ 页面上**绝不显示通道 config 里的地址字段**（`monitor_base` / `pull_url` /
///    `push_url` 全是 `127.0.0.1:879X`，在手机上点开必然打不开 ——
///    2026-10-10 网页后台就为这个被零砚抓到过）。
///    这里只白名单地渲染「人看得懂」的字段：账号名字 / 有没有收款码 / 拉单还是推送。
struct PayChannelsView: View {
    @State private var state: LoadState = .idle
    @State private var chans: [[String: Any]] = []
    @State private var probeItems: [[String: Any]] = []
    @State private var probePick: [String: Any] = [:]
    @State private var busy = ""
    @State private var expanded: Set<String> = []
    @State private var showEdit = false
    @State private var editChan: [String: Any] = [:]

    private var online: Int { chans.filter { $0.b("online") && $0.b("enabled") }.count }
    private var noCode: Int { chans.filter { !$0.b("has_pay_code") }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if AppConfig.isDemo {
                        Text("演示数据（-demo 启动，不连服务器）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    StateBanner(state: state) { Task { await load() } }

                    HStack(spacing: 8) {
                        Button {
                            Task { await probe() }
                        } label: {
                            Label("测一遍所有通道", systemImage: "waveform.path.ecg")
                                .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            Task { await pull() }
                        } label: {
                            Label("拉一次账单", systemImage: "arrow.down.doc")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer(minLength: 0)
                    }

                    if !busy.isEmpty {
                        Text(busy).font(.caption2).foregroundStyle(.secondary)
                    }

                    // ---- 选路结果（探活之后才有）----
                    if !probePick.isEmpty {
                        PayCard(title: "现在会选哪条（探活结果）") {
                            ForEach(pickKeys, id: \.self) { k in
                                let p = probePick.dict(k)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Chip(text: payTypeText(k), tint: payTypeTint(k))
                                        Text(p.s("channel_no").isEmpty ? "—— 没有可用通道" : p.s("channel_no"))
                                            .font(.footnote.weight(.semibold))
                                        Spacer()
                                        Text(p.s("tier_name")).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(p.strings("route").enumerated()), id: \.offset) { _, line in
                                        Text("· \(line)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }

                    // ---- 汇总 ----
                    HStack(spacing: 10) {
                        BigStat(label: "通道", value: "\(chans.count)", icon: "arrow.triangle.branch", tint: .teal)
                        BigStat(label: "在线", value: "\(online)", icon: "checkmark.circle.fill", tint: .green)
                        BigStat(label: "缺收款码", value: "\(noCode)", icon: "qrcode", tint: .orange)
                    }

                    // ---- 通道卡片 ----
                    ForEach(chanNos, id: \.self) { no in
                        if let c = chans.first(where: { $0.s("no") == no }) {
                            chanCard(c)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("收款通道")
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showEdit) {
                NavigationStack {
                    PayChannelEditSheet(channel: editChan) {
                        Task { await load() }
                    }
                }
            }
        }
    }

    /// ForEach 用的稳定 id（通道号）。字典不能当 id，所以先摊平成数组。
    private var chanNos: [String] { chans.map { $0.s("no") } }
    private var pickKeys: [String] { ["wechat", "alipay"] }

    @ViewBuilder
    private func chanCard(_ c: [String: Any]) -> some View {
        let no = c.s("no")
        let tier = c.i("tier")
        let on = c.b("enabled")
        let live = c.b("online")
        let hasCode = c.b("has_pay_code")
        let probe = probeItems.first(where: { $0.s("no") == no })

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(no).font(.callout.weight(.semibold).monospaced())
                Text(c.s("title")).font(.callout).lineLimit(1)
                Spacer(minLength: 4)
                Circle()
                    .fill(!on ? Color.gray : (live ? Color.green : Color.red))
                    .frame(width: 8, height: 8)
                Text(!on ? "已停用" : (live ? "在线" : "掉线"))
                    .font(.caption2)
                    .foregroundStyle(!on ? .secondary : (live ? Color.green : Color.red))
            }

            HStack(spacing: 6) {
                Chip(text: payTypeText(c.s("pay_type")), tint: payTypeTint(c.s("pay_type")))
                Chip(text: c.s("tier_name"), tint: payTierTint(tier))
                Chip(text: hasCode ? "有收款码" : "缺收款码",
                     tint: hasCode ? .green : .red)
                Chip(text: c.s("intake_mode") == "pull" ? "自动拉单" : "等推送",
                     tint: c.s("intake_mode") == "pull" ? .blue : .orange)
            }

            HStack(spacing: 14) {
                Text("今日 " + Fmt.money(c.d("today_amount")))
                    .font(.caption.monospacedDigit())
                Text("昨日 " + Fmt.money(c.d("yest_amount")))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let p = probe {
                    Text(p.b("ok") ? "探活 ✓" : "探活 ✗")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(p.b("ok") ? Color.green : Color.red)
                }
            }

            if let p = probe, !p.b("ok") {
                Text(p.s("why"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if expanded.contains(no) {
                Divider()
                KVRow(k: "账号名字", v: c.s("owner_name"))
                KVRow(k: "收款码", v: hasCode ? "已配置" : "没配（买家扫不到码）")
                KVRow(k: "收款码类型", v: c.s("pay_channel"))
                KVRow(k: "绑定", v: c.s("bind_type"))
                KVRow(k: "接入方式", v: c.s("intake_mode") == "pull" ? "后台自动拉账单" : "等监控端推送")
                KVRow(k: "通道 id", v: "\(c.i("id"))")
                KVRow(k: "更新", v: c.s("updated_at"))
                if !c.s("remark").isEmpty {
                    KVRow(k: "备注", v: c.s("remark"))
                }
            }

            HStack(spacing: 8) {
                Button(expanded.contains(no) ? "收起" : "展开更多") {
                    if expanded.contains(no) { expanded.remove(no) } else { expanded.insert(no) }
                }
                .font(.caption)

                Button(on ? "停用" : "启用") {
                    Task { await toggle(c) }
                }
                .font(.caption)

                Menu {
                    Button("优先级") { Task { await setTier(c, 1) } }
                    Button("路线2") { Task { await setTier(c, 2) } }
                    Button("备用") { Task { await setTier(c, 3) } }
                } label: {
                    Text("等级").font(.caption)
                }

                Button("收款码 / 账号名") {
                    editChan = c
                    showEdit = true
                }
                .font(.caption)

                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 取数 / 动作

    private func load() async {
        if state.isLoading { return }
        state = .loading
        if AppConfig.isDemo {
            chans = PayDemo.channels
            state = .done
            return
        }
        do {
            let r = try await PayAPI.shared.get("/api/channels")
            chans = r.list("items")
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
    }

    private func probe() async {
        busy = "正在逐条探活（跟出码时用的是同一套判活）…"
        defer { busy = "" }
        if AppConfig.isDemo {
            probeItems = PayDemo.probe.list("items")
            probePick = PayDemo.probe.dict("pick")
            chans = PayDemo.channels
            Toast.shared.show("探活完成：4 条通 / 1 条不通")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/channels/probe")
            probeItems = r.list("items")
            probePick = r.dict("pick")
            let ok = probeItems.filter { $0.b("ok") }.count
            Toast.shared.show("探活完成：\(ok) 条通 / \(probeItems.count - ok) 条不通")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "探活失败")
        }
    }

    private func pull() async {
        busy = "正在拉账单…"
        defer { busy = "" }
        if AppConfig.isDemo {
            Toast.shared.show("拉单：新增 1 条流水、认单 1 笔（演示）")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/matches/pull")
            Toast.shared.show("拉单：\(r.i("pulled")) 条通道 · 新增 \(r.i("added")) · 认单 \(r.i("matched"))")
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "拉单失败")
        }
    }

    private func toggle(_ c: [String: Any]) async {
        if AppConfig.isDemo {
            Toast.shared.show("（演示）已切换 \(c.s("no")) 的启停")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/channels/\(c.i("id"))/toggle")
            Toast.shared.show("\(c.s("no")) 已" + (r.b("enabled") ? "启用" : "停用"))
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "切换失败")
        }
    }

    private func setTier(_ c: [String: Any], _ t: Int) async {
        if AppConfig.isDemo {
            Toast.shared.show("（演示）\(c.s("no")) 等级改为 \(t)")
            return
        }
        do {
            let r = try await PayAPI.shared.post("/api/channels/\(c.i("id"))/tier", body: ["tier": t])
            Toast.shared.show("\(c.s("no")) 等级：\(r.s("tier_name"))")
            await load()
        } catch {
            Toast.shared.show((error as? APIError)?.message ?? "改等级失败")
        }
    }
}

/// 改「账号名字 / 收款码」。不传图片，只填文字 —— 支付宝那条路本来就是
/// **填收款码 UUID**（后台自己拼 `https://qr.alipay.com/<uuid>` 出码）。
struct PayChannelEditSheet: View {
    let channel: [String: Any]
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ownerName = ""
    @State private var codeURL = ""
    @State private var busy = false
    @State private var msg = ""

    var body: some View {
        Form {
            Section {
                Text(channel.s("no") + " · " + channel.s("title"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField("账号名字（收款人）", text: $ownerName)
                    .autocorrectionDisabled(true)
                TextField("收款码 UUID / 链接", text: $codeURL)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
            } header: {
                Text("收款码 / 账号名字")
            } footer: {
                Text("支付宝那种带支付链接的收款码，直接把整条链接或 UUID 贴进来即可，"
                     + "后台会自己拼成二维码。清空这一栏 = 清掉这张收款码。")
                    .font(.caption2)
            }
            if !msg.isEmpty {
                Section {
                    Text(msg).font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().padding(.trailing, 6) }
                        Text(busy ? "保存中…" : "保存").font(.callout.weight(.semibold))
                        Spacer()
                    }
                }
                .disabled(busy)
            }
        }
        .navigationTitle("编辑通道")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
            }
        }
        .task {
            ownerName = channel.s("owner_name")
            codeURL = ""
        }
    }

    private func save() async {
        busy = true
        msg = ""
        defer { busy = false }
        if AppConfig.isDemo {
            msg = "（演示）不会真的写库"
            return
        }
        do {
            let r = try await PayAPI.shared.post(
                "/api/channels/\(channel.i("id"))/code-image",
                body: ["owner_name": ownerName, "code_url": codeURL]
            )
            Toast.shared.show(r.b("has_pay_code") ? "已保存（这张通道现在有收款码了）" : "已保存（这张通道还没有收款码）")
            onDone()
            dismiss()
        } catch {
            msg = (error as? APIError)?.message ?? "保存失败"
        }
    }
}
