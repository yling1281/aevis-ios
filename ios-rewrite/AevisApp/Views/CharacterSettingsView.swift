import SwiftUI

/// 角色设置（2026-11-24 新增）。
///
/// 用户明确要求「模型选择放在角色设置里，每个角色单独配」——所以模型不放在聊天页右上角，
/// 而是这里。每角色独立：模型 `aevisModel_<pid>`、温度 `aevisTemp_<pid>`。
///
/// **只放真正能用的东西**（用户反复强调「没实现的功能先不加按钮」）：
/// - 顶部角色卡：头像 + 名字 + tagline；统计：认识天数 / 消息数（第三个没数据就不放）
/// - 模型：右侧当前模型短名，点开模型选择 sheet（大厂 logo + 名称 + 状态胶囊）
/// - 温度：Slider 0.0–2.0，默认 1.0，按角色存；`/v1/llm/chat` 接受 temperature，会真实下发
/// - 清空聊天记录：清本地该 pid 消息（云端无按 pid 删除接口，仅清本地并提示）
///
/// **不放**：编辑资料（服务端 `PUT /v1/persona` 是「用户自画像」不是「角色卡」，
/// 无按 persona.id 的更新接口，宁可不做也不做存不下的表单）、记忆中心、我的人设、
/// 主动唤醒、聊天模式、气泡、头像框、猫粮/资产、礼物、画廊、日记、资源库、对话历史、
/// 拉黑、删除好友（这些后端都没有）。
///
/// 导入聊天记录：本项目无现成客户端导入入口（convert.aevis.cn 是网页工具），不做。
struct CharacterSettingsView: View {
    @EnvironmentObject private var session: Session
    let persona: Persona

    // 模型
    @State private var modelList: [APIClient.LLMModel] = []
    @State private var modelDefaultID: String = "deepseek-flash"
    @State private var selectedModelID: String = ""
    @State private var modelLoading = false
    @State private var modelError = ""
    @State private var showModelSheet = false
    @State private var modelToast = ""

    // 模型健康状态（GET /v1/models/status 的 rows[]，按 model 名匹配）
    @State private var statusByModel: [String: ModelHealth] = [:]

    // 温度
    @State private var temperature: Double = 1.0

    // 清空确认 + 结果提示
    @State private var showClearConfirm = false
    @State private var toast = ""

    /// 一行模型状态。2.8 重做：不再只留一个成功率圆点，
    /// 现在同时带**当前四态**、**时间竖条**、范围/覆盖/平均响应/官方详情。
    struct ModelHealth {
        /// 0...1，nil = 无数据（保留字段，卡片仍显示成功率口径）。
        let rate: Double?
        /// 当前是否可用。不拿 history 推 —— 那是 30 分钟聚合，会滞后半小时。
        let live: LiveState
        /// 竖条序列：true 绿 / false 红；空数组 = 没探测数据，画灰占位。
        let bars: [Bool]
        /// 「近 30 分钟」/「近 24 小时」/「暂无探测数据」。
        let rangeLabel: String
        let coverageMinutes: Int
        let avgLatency: Double?
        /// 官方状态详情；`official_status.stale == true` 时留空，不展示过期结论。
        let officialDetail: String
    }

    /// 实时状态四档。与 ServerStatusView 的四态语义一致，但本文件独立实现，
    /// 不跨文件引用（team-lead 要求只改这一个文件）。
    enum LiveState: String {
        case ok
        case unstable
        case down
        case unknown

        var text: String {
            switch self {
            case .ok: return "正常"
            case .unstable: return "波动"
            case .down: return "异常"
            case .unknown: return "未监控"
            }
        }

        var color: Color {
            switch self {
            case .ok: return Color.hex(0x2FA36B)
            case .unstable: return Color.hex(0xE0A020)
            case .down: return Color.hex(0xE5484D)
            case .unknown: return AE.textSecondary
            }
        }
    }

    private var modelKey: String { "aevisModel_\(persona.id)" }
    private var tempKey: String { "aevisTemp_\(persona.id)" }

    /// 当前生效模型 id（角色选过用选过，否则服务端默认）。
    private var effectiveModelID: String {
        let c = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return modelDefaultID.isEmpty ? "deepseek-flash" : modelDefaultID
    }

    private var effectiveModelName: String {
        if let m = modelList.first(where: { $0.id == effectiveModelID }) { return m.label }
        return effectiveModelID
    }

    private var chatMsgsCount: Int { LocalStore.load(pid: persona.id).count }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                headerCard
                modelCard
                temperatureCard
                dangerCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(Color.paper)
        .navigationTitle("角色设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showModelSheet) { modelSheet }
        .overlay(alignment: .bottom) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(AE.accentDeep.opacity(0.92)))
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .alert("清空聊天记录", isPresented: $showClearConfirm) {
            Button("清空", role: .destructive) { clearLocalChat() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空与「\(persona.name)」在本机的全部聊天记录，此操作不可恢复。")
        }
        .task {
            selectedModelID = UserDefaults.standard.string(forKey: modelKey) ?? ""
            if let t = UserDefaults.standard.object(forKey: tempKey) as? Double {
                temperature = t
            } else {
                temperature = 1.0
            }
            await loadModels()
            await loadModelStatus()
        }
    }

    // MARK: - 顶部角色卡

    private var headerCard: some View {
        VStack(spacing: 12) {
            brandAvatar
                .frame(width: 72, height: 72)

            VStack(spacing: 4) {
                Text(persona.name)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(AE.textPrimary)
                if !persona.tagline.isEmpty {
                    Text(persona.tagline)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }

            // 只放真实可得的统计：消息数（LocalStore 可数）。
            // 「认识天数」没有可靠数据源（本地不存会话创建时间），按「没实现不放」原则不做。
            HStack(spacing: 0) {
                statItem(value: "\(chatMsgsCount)", label: "消息数")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(AE.textPrimary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AE.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    /// 头像：硬缓存（磁盘 + 条件请求 304），AsyncImage 会每次重新下载且断网就没了。
    private var brandAvatar: some View {
        let url = avatarURL(persona.avatar)
        if let url {
            CachedRemoteImage(url: url, scope: "persona:\(persona.id)") { avatarPlaceholder }
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
        } else {
            avatarPlaceholder
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle().fill(
                LinearGradient(colors: [AE.accentLift, AE.accentDeep],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(String(persona.name.prefix(1)))
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
    }

    private func avatarURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("http") { return URL(string: t) }
        return URL(string: t.hasPrefix("/") ? APIClient.base + t : APIClient.base + "/" + t)
    }

    // MARK: - 模型卡

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("模型")
            Button { showModelSheet = true } label: {
                HStack(spacing: 10) {
                    ModelBrandIcon(modelID: effectiveModelID)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(effectiveModelName)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(AE.textPrimary)
                            .lineLimit(1)
                        if let h = statusByModel[statusKeyFor(effectiveModelID)] {
                            Text(h.live.text)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(h.live.color)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("更改")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AE.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AE.textSecondary.opacity(0.5))
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    // MARK: - 温度卡

    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("温度")
                Spacer()
                Text(String(format: "%.1f", temperature))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(AE.accent)
            }
            Slider(value: $temperature, in: 0...2, step: 0.1) { editing in
                // 松手才落盘，拖动中不写
                if !editing { UserDefaults.standard.set(temperature, forKey: tempKey) }
            }
            .tint(AE.accentDeep)
            HStack {
                Text("更严谨").font(.system(size: 10.5)).foregroundStyle(AE.textSecondary)
                Spacer()
                Text("更发散").font(.system(size: 10.5)).foregroundStyle(AE.textSecondary)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    // MARK: - 危险操作卡

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showClearConfirm = true } label: {
                HStack {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                    Text("清空聊天记录")
                        .font(.system(size: 14.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(Color.hex(0xE5484D))
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .glassCard(cornerRadius: AE.cardRadius, material: .thin)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(AE.textSecondary)
    }

    // MARK: - 模型选择 sheet

    @ViewBuilder
    private var modelSheet: some View {
        ZStack {
            GlassBackdrop()
            VStack(spacing: 12) {
                HStack {
                    Text("选择模型")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                    Spacer()
                    Button("完成") { showModelSheet = false }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
                .padding(.horizontal, 20).padding(.top, 16)

                if modelLoading {
                    Spacer(); ProgressView()
                    Text("正在获取模型…").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                    Spacer()
                } else if !modelError.isEmpty && modelList.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30)).foregroundStyle(AE.textSecondary)
                        Text(modelError)
                            .font(.system(size: 13)).foregroundStyle(AE.textSecondary)
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                        Button { Task { await loadModels() } } label: {
                            Text("重试").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 26).padding(.vertical, 9)
                                .background(AE.accentDeep, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            // 按 billing 分组（有 billing 才分组，否则平铺）
                            // 2026-11-25：`per_token` 组内按单价**升序**（便宜的在上面），
                            // 用户一眼能看到同组价差（0.9 vs 3.18 vs 7.27）。
                            // 未知价（0，老服务端）排到最后 —— 不能让它冒充「最便宜」。
                            let perToken = modelList
                                .filter { $0.billing == "per_token" }
                                .sorted { a, b in
                                    let ka = a.estPointsPerMsg > 0 ? a.estPointsPerMsg : Double.greatestFiniteMagnitude
                                    let kb = b.estPointsPerMsg > 0 ? b.estPointsPerMsg : Double.greatestFiniteMagnitude
                                    return ka < kb
                                }
                            // `per_call` 组保持服务端顺序，**不重排**：
                            // 这组只有两三档，服务端已经按产品意图排好（deepseek-web 在最前）。
                            let perCall = modelList.filter { $0.billing == "per_call" }
                            let others = modelList.filter { $0.billing != "per_token" && $0.billing != "per_call" }

                            if !perToken.isEmpty {
                                groupHeader("按量计费")
                                ForEach(perToken) { modelRow($0) }
                            }
                            if !perCall.isEmpty {
                                groupHeader("按次计费")
                                ForEach(perCall) { modelRow($0) }
                            }
                            if !others.isEmpty {
                                if !perToken.isEmpty || !perCall.isEmpty { groupHeader("其它") }
                                ForEach(others) { modelRow($0) }
                            }
                        }
                        .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .glassSheetBackground()
    }

    private func groupHeader(_ s: String) -> some View {
        HStack {
            Text(s)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AE.textSecondary)
            Spacer()
        }
        .padding(.top, 6).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func modelRow(_ m: APIClient.LLMModel) -> some View {
        let isOn = (m.id == effectiveModelID)
        Button { selectModel(m.id) } label: {
            HStack(alignment: .top, spacing: 10) {
                ModelBrandIcon(modelID: m.id)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(m.label.isEmpty ? m.id : m.label)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                            .lineLimit(1)
                        if let h = statusByModel[statusKeyFor(m.id)] {
                            Text(h.live.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(h.live.color)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(h.live.color.opacity(0.14), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if !m.note.isEmpty {
                            Text(m.note)
                                .font(.system(size: 10.5))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(1)
                        }
                        // 计费方式 + 单价（2026-11-25）：同组价差最大 72 倍，
                        // 点选之前必须能看见「这条消息大概扣多少墨点」，
                        // 否则用户聊两句发现额度掉一大块，观感就是「有毒」。
                        if !m.priceText.isEmpty {
                            Text(m.priceText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(m.isPricey ? AE.memberBadge : AE.accent)
                                .lineLimit(1)
                        }
                    }

                    // 2.8：History 竖条 + 探测元信息。无数据时只写灰字，不画假绿。
                    if let h = statusByModel[statusKeyFor(m.id)] {
                        historyBlock(h)
                    }
                }
                Spacer(minLength: 0)
                if isOn {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AE.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 14, material: .thin,
                       tintOpacity: isOn ? 0.22 : 0.08,
                       strokeColor: isOn ? AE.brandPurple : .white,
                       strokeOpacity: isOn ? 0.9 : 0.18)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 历史竖条（本文件内实现，不跨文件引用）

    /// 12pt 高竖条：绿=通过、红=失败，宽度按可用宽度自适应铺满。
    /// 用 GeometryReader 而不是固定宽度，卡片在 iPad / 分屏下也能铺满。
    private func historyBars(_ bars: [Bool]) -> some View {
        GeometryReader { geo in
            let usable = max(geo.size.width, 1)
            let count = max(bars.count, 1)
            let gap: CGFloat = bars.count > 32 ? 1 : 2
            let width = max(1, (usable - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { pair in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(pair.element ? Color.hex(0x2FA36B) : Color.hex(0xE5484D))
                        .frame(width: width, height: 12)
                }
            }
            .frame(width: usable, alignment: .leading)
        }
        .frame(height: 12)
    }

    private func historyBlock(_ h: ModelHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if h.bars.isEmpty {
                Text("暂无探测数据")
                    .font(.system(size: 10))
                    .foregroundStyle(AE.textSecondary)
            } else {
                historyBars(h.bars)
                HStack(spacing: 6) {
                    Text(h.rangeLabel)
                    if h.coverageMinutes > 0 {
                        Text("覆盖 \(h.coverageMinutes) 分钟")
                    }
                    if let avg = h.avgLatency {
                        Text("平均响应 \(String(format: "%.1f", avg)) 秒")
                    }
                    if !h.officialDetail.isEmpty {
                        Text(h.officialDetail)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(AE.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
        }
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 数据

    @MainActor
    private func loadModels() async {
        modelLoading = true
        modelError = ""
        do {
            let list = try await APIClient.llmModels()
            modelDefaultID = list.defaultID
            modelList = list.models
            if modelList.isEmpty { modelError = "服务端暂未下发可用模型" }
        } catch {
            modelError = "模型列表获取失败：\(error.localizedDescription)"
        }
        modelLoading = false
    }

    /// 拉模型健康状态（公开接口）。生产返回 `code:0` + `data.rows[]`，
    /// 老部署可能给 `code:200`——APIClient.request 两种都接受，这里再兜一次信封。
    ///
    /// 时间序列降级顺序：recent（近 30 分钟逐点）→ history（30 分钟一桶，近 24 小时）
    /// → 都没有就空 bars，界面写「暂无探测数据」，绝不画假绿。
    @MainActor
    private func loadModelStatus() async {
        guard let json = try? await APIClient.request("/v1/models/status") else { return }
        if let code = (json["code"] as? NSNumber)?.intValue, code != 0 && code != 200 { return }
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["rows"] as? [[String: Any]]) ?? []
        var map: [String: ModelHealth] = [:]
        for row in rows {
            guard let model = row["model"] as? String, !model.isEmpty else { continue }
            map[normalizedModel(model)] = parseModelHealth(row)
        }
        statusByModel = map
    }

    /// 一行 status 数据 → ModelHealth。所有数字都走 NSNumber，兼容 Int / Double / NSNumber。
    private func parseModelHealth(_ row: [String: Any]) -> ModelHealth {
        let avg = (row["avg_latency_sec"] as? NSNumber)?.doubleValue
        let coverage = (row["coverage_minutes"] as? NSNumber)?.intValue ?? 0

        // 1) recent：1=正常 / 0=异常。兼容 [Int]、[NSNumber]、[Double] 三种桥接。
        var bars: [Bool] = []
        var range = ""
        var rate: Double? = nil
        if let raw = row["recent"] as? [Any], !raw.isEmpty {
            let values = raw.compactMap { boolNumber($0) }
            if values.count == raw.count {
                bars = values.map { $0 >= 0.5 }
                rate = Double(bars.filter { $0 }.count) / Double(bars.count)
                range = "近 30 分钟"
            }
        }

        // 2) history：只取 total>0 的桶，ok/total >= 0.5 记绿（team-lead 口径）。
        var okSum = 0
        var totalSum = 0
        var historyBarsValue: [Bool] = []
        let history = (row["history"] as? [[String: Any]]) ?? []
        for bucket in history {
            let total = (bucket["total"] as? NSNumber)?.intValue ?? 0
            guard total > 0 else { continue }
            let ok = (bucket["ok"] as? NSNumber)?.intValue ?? 0
            okSum += ok
            totalSum += total
            historyBarsValue.append(Double(ok) / Double(total) >= 0.5)
        }
        if bars.isEmpty && !historyBarsValue.isEmpty {
            bars = historyBarsValue
            rate = Double(okSum) / Double(totalSum)
            range = "近 24 小时"
        }
        if rate == nil {
            rate = (row["success_rate"] as? NSNumber)?.doubleValue
                ?? (row["rate"] as? NSNumber)?.doubleValue
        }
        if range.isEmpty { range = bars.isEmpty ? "暂无探测数据" : "近 30 分钟" }

        // 3) 官方状态：stale=true 的结论不展示，避免拿过期信息误导。
        var officialDetail = ""
        if let official = row["official_status"] as? [String: Any] {
            let stale = (official["stale"] as? NSNumber)?.boolValue ?? true
            if !stale { officialDetail = (official["detail"] as? String) ?? "" }
        }

        return ModelHealth(
            rate: rate,
            live: parseLiveState(row),
            bars: bars,
            rangeLabel: range,
            coverageMinutes: coverage,
            avgLatency: avg,
            officialDetail: officialDetail
        )
    }

    /// 实时四态：providers[].alive 是最近一次探测结论，优先于聚合 history。
    /// 没有 providers 时看 status / official_status，两者都没有才「未监控」。
    private func parseLiveState(_ row: [String: Any]) -> LiveState {
        let providers = (row["providers"] as? [[String: Any]]) ?? []
        let anyAlive = providers.contains { p in
            (p["alive"] as? NSNumber)?.boolValue ?? (p["alive"] as? Bool) ?? false
        }
        let status = ((row["status"] as? String) ?? "").lowercased()

        var officialState = ""
        var officialStale = true
        if let official = row["official_status"] as? [String: Any] {
            officialState = ((official["state"] as? String) ?? "").lowercased()
            officialStale = (official["stale"] as? NSNumber)?.boolValue ?? true
        }
        let officialBad = !officialStale
            && ["down", "outage", "incident", "major_outage"].contains(officialState)

        if officialBad || status == "down" || status == "error" { return .down }
        if status == "degraded" || status == "warn" || status == "unstable" { return .unstable }
        if providers.isEmpty { return .unknown }
        if anyAlive { return .ok }
        return .down
    }

    /// Bool / NSNumber / Int / Double 都归一化成 Double，供 recent 的 >=0.5 判定。
    private func boolNumber(_ value: Any) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let b = value as? Bool { return b ? 1 : 0 }
        return nil
    }

    /// 模型 id 归一到「品牌前缀」用于匹配 status 行（deepseek-flash → deepseek）。
    private func normalizedModel(_ id: String) -> String {
        if id.hasPrefix("deepseek") { return "deepseek" }
        if id.hasPrefix("gemini") { return "gemini" }
        if id.hasPrefix("claude") { return "claude" }
        return id
    }

    /// 状态行匹配 key：先按精确 id，再按品牌前缀。
    private func statusKeyFor(_ id: String) -> String {
        if statusByModel[id] != nil { return id }
        return normalizedModel(id)
    }

    @MainActor
    private func selectModel(_ id: String) {
        selectedModelID = (id == modelDefaultID) ? "" : id
        UserDefaults.standard.set(selectedModelID, forKey: modelKey)
        showModelSheet = false
        let name = modelList.first(where: { $0.id == id })?.label ?? id
        withAnimation { toast = "已切换到 \(name)" }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { toast = "" } }
        }
    }

    @MainActor
    private func clearLocalChat() {
        LocalStore.save(pid: persona.id, msgs: [])
        LocalStore.setUnread(persona.id, 0)
        withAnimation { toast = "已清空本机聊天记录" }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { toast = "" } }
        }
    }
}

/// 大厂模型 logo（SwiftUI 矢量自绘，28×28 圆角 8）。
/// 用户要求「搬运那些大厂的头像」但没有网络图片资源，这里用近似标志：
/// deepseek → 深蓝底白鲸鱼；gemini → 蓝紫渐变白四角星；claude → 橙棕底白星芒；
/// 其它（codex 等）→ 中性灰底 sparkles。按 id 前缀匹配。
struct ModelBrandIcon: View {
    let modelID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(brand.background)
            brand.glyph
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private enum Brand { case deepseek, gemini, claude, generic }

    private var brand: (background: AnyShapeStyle, glyph: AnyView) {
        let id = modelID.lowercased()
        if id.hasPrefix("deepseek") {
            return (
                AnyShapeStyle(Color.hex(0x4D6BFE)),
                AnyView(WhaleGlyph().frame(width: 18, height: 18))
            )
        }
        if id.hasPrefix("gemini") {
            return (
                AnyShapeStyle(LinearGradient(colors: [Color.hex(0x4E7BFF), Color.hex(0x9B72FF)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)),
                AnyView(FourPointStar().frame(width: 16, height: 16))
            )
        }
        if id.hasPrefix("claude") {
            return (
                AnyShapeStyle(Color.hex(0xD97757)),
                AnyView(StarBurst().frame(width: 17, height: 17))
            )
        }
        return (
            AnyShapeStyle(Color.hex(0x8A8F99)),
            AnyView(Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)))
        )
    }
}

/// 鲸鱼剪影（简洁弧线 + 尾鳍）。
private struct WhaleGlyph: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                // 身体：一条饱满的弧
                p.move(to: CGPoint(x: w * 0.12, y: h * 0.62))
                p.addQuadCurve(to: CGPoint(x: w * 0.82, y: h * 0.5),
                               control: CGPoint(x: w * 0.45, y: h * 0.18))
                p.addQuadCurve(to: CGPoint(x: w * 0.12, y: h * 0.62),
                               control: CGPoint(x: w * 0.45, y: h * 0.92))
                // 尾鳍
                p.move(to: CGPoint(x: w * 0.82, y: h * 0.5))
                p.addLine(to: CGPoint(x: w * 0.96, y: h * 0.34))
                p.addLine(to: CGPoint(x: w * 0.92, y: h * 0.56))
                p.addLine(to: CGPoint(x: w * 0.98, y: h * 0.72))
                p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.56))
            }
            .fill(.white)
        }
    }
}

/// 四角星芒（Gemini 近似）。
private struct FourPointStar: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: w * 0.5, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: h * 0.5),
                               control: CGPoint(x: w * 0.5, y: h * 0.5))
                p.addQuadCurve(to: CGPoint(x: w * 0.5, y: h),
                               control: CGPoint(x: w * 0.5, y: h * 0.5))
                p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.5),
                               control: CGPoint(x: w * 0.5, y: h * 0.5))
                p.addQuadCurve(to: CGPoint(x: w * 0.5, y: 0),
                               control: CGPoint(x: w * 0.5, y: h * 0.5))
            }
            .fill(.white)
        }
    }
}

/// 放射星芒（Claude 近似，8 条短线）。
private struct StarBurst: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let cx = w / 2, cy = h / 2
            Path { p in
                let n = 8
                for i in 0..<n {
                    let a = Double(i) / Double(n) * 2 * .pi
                    let inner = min(w, h) * 0.14
                    let outer = min(w, h) * 0.5
                    p.move(to: CGPoint(x: cx + cos(a) * inner, y: cy + sin(a) * inner))
                    p.addLine(to: CGPoint(x: cx + cos(a) * outer, y: cy + sin(a) * outer))
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: max(1.6, min(w, h) * 0.1),
                                               lineCap: .round))
        }
    }
}
