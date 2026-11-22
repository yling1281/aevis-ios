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

    struct ModelHealth {
        let rate: Double?      // 0...1，nil = 无数据
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
    private var brandAvatar: some View {
        let url = avatarURL(persona.avatar)
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .empty: avatarPlaceholder
                default: avatarPlaceholder
                }
            }
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
                        if let h = statusByModel[statusKeyFor(effectiveModelID)],
                           let label = healthLabel(h.rate) {
                            Text(label.text)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(label.color)
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
                            let perToken = modelList.filter { $0.billing == "per_token" }
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
                        if let h = statusByModel[statusKeyFor(m.id)], let lb = healthLabel(h.rate) {
                            Text(lb.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(lb.color)
                                .padding(.horizontal, 6).padding(.vertical, 1.5)
                                .background(lb.color.opacity(0.14), in: Capsule())
                        }
                    }
                    HStack(spacing: 6) {
                        if !m.note.isEmpty {
                            Text(m.note)
                                .font(.system(size: 10.5))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(1)
                        }
                        if !m.billingText.isEmpty {
                            Text(m.billingText)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(AE.accent)
                        }
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

    /// 拉模型健康状态（公开接口），按 rows[].model 汇总最近 history 的 ok/total。
    @MainActor
    private func loadModelStatus() async {
        guard let json = try? await APIClient.request("/v1/models/status") else { return }
        let d = (json["data"] as? [String: Any]) ?? json
        let rows = (d["rows"] as? [[String: Any]]) ?? []
        var map: [String: ModelHealth] = [:]
        for r in rows {
            guard let model = r["model"] as? String else { continue }
            let hist = (r["history"] as? [[String: Any]]) ?? []
            var ok = 0, total = 0
            for h in hist {
                ok += (h["ok"] as? NSNumber)?.intValue ?? 0
                total += (h["total"] as? NSNumber)?.intValue ?? 0
            }
            let rate: Double? = total > 0 ? Double(ok) / Double(total) : (r["success_rate"] as? Double)
            map[normalizedModel(model)] = ModelHealth(rate: rate)
        }
        statusByModel = map
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

    private func healthLabel(_ rate: Double?) -> (text: String, color: Color)? {
        guard let r = rate else { return nil }
        if r >= 0.97 { return ("正常", Color.hex(0x2FA36B)) }
        if r >= 0.80 { return ("波动", Color.hex(0xE0A020)) }
        return ("异常", Color.hex(0xE5484D))
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
