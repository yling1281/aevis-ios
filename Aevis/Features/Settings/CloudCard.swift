import SwiftUI

/// 「姜言云端」设置卡 —— 充值 + 转移账号 + 内置 API 状态。
///
/// ## ⭐ 充值和网页端**是同一笔账**
/// 后端 `/v1/*` 的鉴权是同一个 `current_user()`（`app.py:370`），
/// 拿的是同一个 `sys_user` → 同一个 `tenant_id` → 同一份 `balance_micro`。
/// 所以在 App 里充的钱，网页版「我的钱包」立刻看得到；反过来也一样。
/// **不要**在 iOS 这边再搞一套余额 —— 那是两本账，用户会觉得钱丢了。
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
/// 钱到账后走的是**网页端那套 `credit_order`**，所以套餐/余额的履约逻辑
/// 两边完全一致，不存在"iOS 充值只充余额、不改套餐"这种分叉。
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
        } catch let e {
            // ⚠️ catch 的隐式绑定必须改名：写成 `catch { error = … error.localizedDescription }`
            //    时，左边的 `error` 撞上 @State 那个 `error` ——
            //    catch 的隐式 error 是 let 绑定、不可写 ⇒ 编译报
            //    "cannot assign to value: 'error' is immutable"。
            error = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
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

    // ⚠️ 参数类型必须是 `some ShapeStyle` 而不是 `Color`：
    //    `.tertiary` / `.secondary` 是**层级样式**（`HierarchicalShapeStyle`），
    //    不是具体颜色 —— 声明成 `Color` 的话
    //    「member 'tertiary' in 'Color' produces result of type 'some ShapeStyle'」。
    private func hint<S: ShapeStyle>(_ text: String, color: S) -> some View {
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

/// 转移账号：**四端联动的唯一通道**。
///
/// ## 为什么「联动」只能是备份码
/// 企业微信 / 微信 BOT / iOS / QQ 四端各自的消息、日记、经期记录存在**不同的地方**
/// （企微在腾讯那侧、BOT 在 4-4 的网关、iOS 在本机、QQ 在桥接服务），
/// 唯一能把它们连起来的只有云端这个账号 —— 而账号之间的数据搬运，后端只提供
/// `/v1/backup/*` 这一套。所以「联动」= 备份码，没有第二条路。
///
/// ## 流程
/// - 老设备：先 `pull()` 把云端已有的日记/记忆/周期记录取回来，打包成 `ABCD-1234`
/// - 新设备：登录**同一账号** → 输入这个码 → 整体搬过来
///
/// ## 三个不能省的约束
/// 1. **一个码只能被认领一次**（后端 `status` 从 `pending` 变 `claimed`）。
/// 2. **30 天过期**（后端 `_BK_DAYS`）。
/// 3. **单包 2MB 上限**（后端 `3 * 1024 * 1024` 压缩后）。超了要让用户先精简日记，
///    别默默截断 —— 截断了用户以为搬完了，其实在丢东西。
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
                 + "备份码 30 天内有效。")
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
            // ⚠️ 文案别写成"只能认领一次" —— 后端只拦**别的账号**再认领
            //    （`if r['tenant_id'] and r['tenant_id'] != tid`），
            //    **同一个账号重复输入是允许的**（换设备时手滑输两遍很正常，
            //    拦掉反而让人以为码废了）。
            Text("输入旧设备给你的备份码。同一个账号可以重复输入，换设备时输错一遍也没关系。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

    /// 走「先 seed 造一个码 → 再 pull → 再造正式码」三步。
    ///
    /// ⚠️ **不能直接 pull 再造码**（2026-10-19 实测踩到）：`/v1/backup/pull` 挑的是
    ///    `status='claimed'` 的最新一条备份码，而**从没造过码的账号一条都没有**
    ///    ⇒ pull 直接 404 ⇒ 界面显示"云端还没有可备份的数据"，
    ///    但用户明明刚写了几条日记，这就是**假报错**。
    ///
    /// 所以先造一个最小的 seed 码（登录态下建出来就是 `claimed`，
    /// 后端 `v1_backup_code` 里 `'claimed' if tid else 'pending'`），
    /// pull 才有东西可拉 —— 它会把 `/v1/data/<k>` 里各项一并合并进来。
    private func makeCode() async {
        busy = true
        defer { busy = false }
        do {
            // ① seed：造一个占位码，把这个账号的 pull 入口打通
            _ = try await BackupCodeService.create(payload: ["seed": 1], source: "ios")

            // ② 拉云端已有数据（`call` 已经拆过外层 data，这里直接就是 data 字典）
            let pulled = try await BackupCodeService.pull()
            let data = (pulled["data"] as? [String: Any]) ?? [:]
            guard !data.isEmpty else {
                message = "云端还没有可备份的数据。写几条日记或记忆再来试试。"
                return
            }

            // ③ 正式码：带上真正的数据
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