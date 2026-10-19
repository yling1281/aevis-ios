import SwiftUI

/// 「姜言云端」设置卡 —— 充值 + 转移账号 + 内置 API 状态。
///
/// ## 为什么单独一张卡，不塞进 `AccountCard`
/// `AccountCard` 管的是**账号站**（这台设备是谁的：登录 / 资料 / 设备列表）。
/// 这里管的是**业务站**（这个账号里有什么：余额、套餐、备份码）。
/// 两套域名两套令牌，混在一起以后排查登录问题会疯。
///
/// ## 充值为什么跳网页而不是 App 内付款
/// 微信 / 支付宝的付款确认必须调起**系统**组件，`WKWebView` 里拿不到回调，
/// 表现就是「付了钱余额没动」。所以这里只负责**开单**（`/v1/orders`），
/// 剩下的交给系统浏览器，付完回 App 再轮询 `/v1/orders/<no>`。
struct CloudCard: View {

    @ObservedObject private var settings = AppSettings.shared

    @State private var wallet: AevisCloud.Wallet?
    @State private var products: [AevisCloud.Product] = []
    @State private var busy = false
    @State private var note: String?
    @State private var error: String?

    @State private var showingTopUp = false
    @State private var showingTransfer = false

    private var signedIn: Bool { AevisCloud.isSignedIn }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("姜言云端")

            walletRow
            rule
            apiRow
            rule
            actionRow

            if let note {
                rule
                hint(note, color: .secondary)
            }
            if let error {
                rule
                hint(error, color: .orange)
            }
            rule
            hint("充值和搬家都在云端完成，余额按这个账号算 —— "
                 + "跟企业微信、微信 BOT 那几端共用同一份账。", color: .tertiary)
        }
        .task {
            guard signedIn else { return }
            await refresh()
        }
        .sheet(isPresented: $showingTopUp) {
            TopUpSheet(products: products) { note = $0 }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingTransfer) {
            TransferSheet()
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - 行

    private var walletRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text(signedIn ? "余额" : "未登录")
                    .font(.aevis(15))
                if signedIn, let wallet {
                    Text("¥\(String(format: "%.2f", wallet.balance))"
                         + (wallet.expireAt.isEmpty ? "" : " · 到期 \(wallet.expireAt.prefix(10))"))
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                } else {
                    Text(signedIn ? "正在取…" : "先登录姜言账号才能充值和搬家")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if signedIn {
                Button(busy ? "…" : "刷新") { Task { await refresh() } }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
                    .disabled(busy)
            }
        }
    }

    private var apiRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("内置 API")
                    .font(.aevis(15))
                Text(usingAevisAPI
                     ? "正在用姜言云端 · \(settings.model)"
                     : "当前用 \(settings.baseURL.isEmpty ? "未设置" : settings.baseURL)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !usingAevisAPI {
                Button("切到云端") { applyAevisAPI() }
                    .font(.aevis(14))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var actionRow: some View {
        row {
            VStack(alignment: .leading, spacing: 3) {
                Text("充值 / 转移账号")
                    .font(.aevis(15))
                Text("标准版 ¥25 · 超值版 ¥40，按月计费")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                Button("充值") {
                    if signedIn { showingTopUp = true }
                    else { note = "先登录姜言账号。" }
                }
                .buttonStyle(.borderless)
                .font(.aevis(14))
                .foregroundStyle(usingAevisAPI ? Color.accentColor : .secondary)

                Button("转移账号") {
                    if signedIn { showingTransfer = true }
                    else { note = "先登录姜言账号。" }
                }
                .buttonStyle(.borderless)
                .font(.aevis(14))
            }
            .disabled(!signedIn)
        }
    }

    // MARK: - 动作

    private func refresh() async {
        busy = true
        defer { busy = false }
        do {
            async let w = AevisCloud.wallet()
            async let p = AevisCloud.products()
            wallet = try await w
            products = try await p
            error = nil
        } catch {
            error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 「内置 API」的实际判定：**地址**和兼容层一致才算用上了。
    /// 只比地址不比 model —— 用户自己换个模型名很正常，不该因此显示"没在用"。
    private var usingAevisAPI: Bool {
        settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(AevisCloud.chatBase)
    }

    /// 不用 `ProviderPreset` 的写入口，是为了不动 `syncIntoActiveProfile` 那套回写逻辑 ——
    /// 这里只改当前生效的两栏，语义更窄也更安全。
    private func applyAevisAPI() {
        settings.baseURL = AevisCloud.chatBase
        settings.model = "aevis-chat"
        note = "已经切到姜言云端。按这个账号的余额计费。"
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.aevis(11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }
}

/// 充值面板：选套餐 → 开单 → 跳系统浏览器 → 回 App 轮询。
struct TopUpSheet: View {

    let products: [AevisCloud.Product]
    var onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var pendingOrder = ""
    @State private var message = ""
    /// 卡片传进来的可能是空数组（比如刚进 App 还没拉完），
    /// 这里自己兜底拉一次 —— 但要**真的回写 state**，否则拉了也白拉，
    /// 界面还是那句"套餐加载中…"。
    @State private var rows: [AevisCloud.Product] = []

    private var list: [AevisCloud.Product] { rows.isEmpty ? products : rows }

    var body: some View {
        NavigationStack {
            List {
                if list.isEmpty {
                    Text("套餐加载中…")
                        .foregroundStyle(.secondary)
                }
                ForEach(list) { p in
                    Button {
                        Task { await order(p) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(p.name).font(.headline)
                                    if !p.badge.isEmpty {
                                        Text(p.badge)
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(p.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("¥\(String(format: "%.0f", p.amount))")
                                .font(.aevis(16, weight: .semibold))
                        }
                    }
                    .disabled(busy)
                }

                if !message.isEmpty {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("充值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                guard products.isEmpty else { rows = products; return }
                rows = (try? await AevisCloud.products()) ?? []
            }
        }
    }

    private func order(_ p: AevisCloud.Product) async {
        busy = true
        defer { busy = false }
        do {
            let o = try await AevisCloud.createOrder(pid: p.pid)
            pendingOrder = o.orderNo
            if o.mock {
                message = o.msg.isEmpty ? "支付通道还没配好，暂时无法付款。" : o.msg
                return
            }
            // ⚠️ 走**系统浏览器**：内嵌 WebView 拿不到微信/支付宝的付款回调。
            AevisCloud.openCashier(o.payUrl.isEmpty ? o.qrUrl : o.payUrl)
            message = "已跳到收银台，付完回到 App 会自动查一次。"
            poll()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 轮询到已支付就收工，最多 10 分钟（收银台那边 15 分钟过期）。
    private func poll() {
        let no = pendingOrder
        guard !no.isEmpty else { return }
        Task {
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 15 * NSEC_PER_SEC)
                guard (try? await AevisCloud.orderPaid(no)) == true else { continue }
                message = "充值成功。"
                onDone("充值成功，余额已经到账。")
                return
            }
            message = "还没查到付款结果。钱付了但没到账的话，回网页版「我的订单」看一眼。"
        }
    }
}

/// 转移账号：老设备导出备份码，新设备输入备份码。
struct TransferSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var code = ""
    @State private var created: BackupCodeService.Created?
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text("导出备份码").tag(0)
                    Text("输入备份码").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if tab == 0 { exportPane } else { importPane }
            }
            .navigationTitle("转移账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 导出侧：把云端已有的日记 / 记忆 / 周期记录打包成一个码。
    private var exportPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("在这台设备上点下面生成，会得到一个备份码。"
                 + "在另一台设备登录同一个账号后输入它，日记、记忆、周期记录会整体搬过去。\n"
                 + "备份码 30 天内有效，只能被认领一次。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let created {
                VStack(spacing: 8) {
                    Text(created.code)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("有效期到 \(created.expireAt)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button(busy ? "生成中…" : "生成备份码") {
                Task { await makeCode() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
            .frame(maxWidth: .infinity)

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private var importPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("输入旧设备给你的备份码。只能认领一次，认领完这个码就作废了。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)

            TextField("ABCD-1234", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            Button(busy ? "搬家中…" : "确认搬家") {
                Task { await claim() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || BackupCodeService.normalize(code).isEmpty)
            .frame(maxWidth: .infinity)

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    /// 走 `/v1/backup/pull` —— 它把**云端已存**的日记/记忆/周期记录整包取回来，
    /// 比让 iOS 自己拼 payload 更靠得住（人设、设置它会一并带上）。
    ///
    /// ⚠️ `AevisCloud.call` 已经把外层 `{"code":200,"data":{…}}` 的 `data` 拆出来了，
    ///    所以这里 `pulled` **就是** `{code, exportAt, data:{…}}`，
    ///    数据在 `pulled["data"]` —— 别再多剥一层（剥两次必然拿到空，
    ///    界面就会显示"云端还没有可备份的数据"，而其实是解错了）。
    private func makeCode() async {
        busy = true
        defer { busy = false }
        do {
            let pulled = try await BackupCodeService.pull()
            let data = (pulled["data"] as? [String: Any]) ?? pulled
            guard !data.isEmpty else {
                message = "云端还没有可备份的数据。"
                return
            }
            created = try await BackupCodeService.create(payload: data, source: "ios")
            message = "备份好了。"
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func claim() async {
        busy = true
        defer { busy = false }
        do {
            let normalized = BackupCodeService.normalize(code)
            let stats = try await BackupCodeService.claim(normalized)
            let summary = stats.isEmpty
                ? "搬家完成。"
                : "搬家完成：" + stats.map { "\($0.key) \($0.value)" }.joined(separator: "、")
            message = summary
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}