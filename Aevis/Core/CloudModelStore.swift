import Foundation

/// 云端可选模型（由后端 `/v1/llm/models` 下发）。
///
/// ⚠️ 计价口径在后端（DeepSeek 官方价 × 1.5，1 元 = 300 积分），
///    这里**只负责展示**，不参与任何金额计算 —— 免得两边算出两个价。
struct CloudModel: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let note: String
    let isDefault: Bool
    /// 我们的价（积分 / 百万 token）
    let inputPointsPerM: Double
    let outputPointsPerM: Double
    /// 官方价（元 / 百万 token），用于展示"我们比官方贵多少"
    let officialInputYuanPerM: Double
    let officialOutputYuanPerM: Double
    /// 按次计费时每次多少积分（0 = 这个模型按 token 算）。
    /// 2026-11-12 用户：「按次计费也要把价格写出来，按量计费也要把价格写出来」。
    var perCallPoints: Double = 0
    /// "per_token" / "per_call"
    var billing: String = "per_token"

    enum CodingKeys: String, CodingKey {
        case id, label, note
        case isDefault = "default"
        case inputPointsPerM, outputPointsPerM
        case officialInputYuanPerM, officialOutputYuanPerM
        case perCallPoints, billing
    }

    /// ⚠️ **必须显式写这个初始化器**。
    ///
    /// 一旦写了 `init(from decoder:)`，编译器就**不再自动合成**成员初始化器 ——
    /// 于是 `CloudModel(id:label:note:isDefault:...)` 这种写法会报
    /// 「extra arguments … missing argument for parameter 'from'」。
    /// 所以这里把全参初始化器补回来（兜底名单就是用它建的）。
    init(id: String, label: String, note: String, isDefault: Bool,
         inputPointsPerM: Double, outputPointsPerM: Double,
         officialInputYuanPerM: Double, officialOutputYuanPerM: Double,
         perCallPoints: Double = 0, billing: String = "per_token") {
        self.id = id
        self.label = label
        self.note = note
        self.isDefault = isDefault
        self.inputPointsPerM = inputPointsPerM
        self.outputPointsPerM = outputPointsPerM
        self.officialInputYuanPerM = officialInputYuanPerM
        self.officialOutputYuanPerM = officialOutputYuanPerM
        self.perCallPoints = perCallPoints
        self.billing = billing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? id
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        inputPointsPerM = (try? c.decode(Double.self, forKey: .inputPointsPerM)) ?? 0
        outputPointsPerM = (try? c.decode(Double.self, forKey: .outputPointsPerM)) ?? 0
        officialInputYuanPerM = (try? c.decode(Double.self, forKey: .officialInputYuanPerM)) ?? 0
        officialOutputYuanPerM = (try? c.decode(Double.self, forKey: .officialOutputYuanPerM)) ?? 0
        perCallPoints = (try? c.decode(Double.self, forKey: .perCallPoints)) ?? 0
        billing = (try? c.decode(String.self, forKey: .billing)) ?? "per_token"
    }

    /// 「输入 1 元 ≈ 多少积分」这类提示用得上。
    var priceHint: String {
        if billing == "per_call", perCallPoints > 0 {
            return String(format: "每次 %.0f 积分", perCallPoints)
        }
        return String(format: "输入 %.0f 积分 / 百万字，输出 %.0f 积分 / 百万字",
                      inputPointsPerM, outputPointsPerM)
    }

    /// 归到哪个厂商分组。
    ///
    /// 后端目前只下发 `id` / `label`，没有 `vendor` 字段，所以这里按名字认。
    /// 认不出来的一律进「其他」，**不隐藏** —— 宁可多一行，也不能让用户看不到模型
    /// （用户 2026-11-11：型号不固定，随时会上下架）。
    var vendor: String {
        let s = (id + " " + label).lowercased()
        if s.contains("deepseek") { return "DeepSeek" }
        if s.contains("claude") || s.contains("sonnet")
            || s.contains("opus") || s.contains("haiku") { return "Claude" }
        if s.contains("gemini") || s.contains("vertex") { return "Gemini" }
        if s.contains("gpt") || s.contains("openai") { return "GPT" }
        if s.contains("glm") || s.contains("chatglm") || s.contains("zhipu") { return "GLM" }
        if s.contains("kimi") || s.contains("moonshot") { return "Kimi" }
        if s.contains("minimax") { return "MiniMax" }
        if s.contains("grok") { return "Grok" }
        if s.contains("qwen") || s.contains("tongyi") { return "Qwen" }
        return "其他"
    }
}

/// 一个厂商 + 它名下的模型。
struct CloudModelGroup: Identifiable {
    let vendor: String
    let models: [CloudModel]
    var id: String { vendor }
}

/// 云端模型的拉取 + 本地缓存。
///
/// 为什么不每次都拉：模型列表变动极少，缓存 6 小时；
/// 拉失败就用缓存，再不行用内置兜底名单（保证 App 不会因为网络问题没法用）。
@MainActor
final class CloudModelStore: ObservableObject {
    static let shared = CloudModelStore()

    @Published private(set) var models: [CloudModel] = []
    @Published private(set) var loadedAt: Date = .distantPast
    @Published private(set) var lastError: String = ""
    /// 正在拉取（界面据此显示转圈）
    @Published private(set) var loading = false

    /// 上游**当前明确离线**的模型 id（2026-11-12）。
    ///
    /// 只装 `/v1/llm/status` 里 `online == false` 的那些 —— 状态页里没监控的模型
    /// 不进这个集合，照常当可用（没数据 ≠ 挂了）。
    /// 界面只拿它点灰点/置灰，**不显示任何文字**（用户要求）。
    @Published private(set) var offlineIDs: Set<String> = []

    private let cacheKey = "aevis.cloudModels.v1"
    /// 缓存多久算旧。
    ///
    /// 🔴 2026-11-12 用户：「模型的名称你还是没有改 iOS 版本的」。
    ///    根因不是没改，是**永远拉不到新名字**：`loadCache()` 以前把 `loadedAt`
    ///    写成"现在"，于是每次启动都重新开始计时，`refresh()` 一直走"还没过期"提前返回 ——
    ///    只要用户常开 App，缓存里的旧名字就永远换不掉。
    ///    现在 `loadedAt` 用**落盘时间**，TTL 收到 30 分钟，后台改名后最迟半小时生效。
    private let ttl: TimeInterval = 30 * 60
    /// 缓存写入时间（UserDefaults 里的秒级时间戳）
    private let cacheStampKey = "aevis.cloudModels.v1.at" 

    /// 兜底名单（与后端 PRICE_TABLE 对齐）。后端不可达时至少让用户能选。
    ///
    /// ⚠️ **非隔离**（不加 @MainActor）：`ConfigShare` 在非隔离上下文里要读它。
    static let fallback: [CloudModel] = [
        CloudModel(id: "deepseek-flash", label: "DeepSeek V4.1 Flash",
                   note: "日常聊天，快而省。默认推荐。", isDefault: true,
                   inputPointsPerM: 300, outputPointsPerM: 1200,
                   officialInputYuanPerM: 1, officialOutputYuanPerM: 4),
        CloudModel(id: "deepseek-chat", label: "DeepSeek Chat",
                   note: "通用对话，质量与速度均衡。", isDefault: false,
                   inputPointsPerM: 600, outputPointsPerM: 2400,
                   officialInputYuanPerM: 2, officialOutputYuanPerM: 8),
        CloudModel(id: "deepseek-reasoner", label: "DeepSeek Reasoner",
                   note: "会先想再答，适合复杂问题；更慢更贵。", isDefault: false,
                   inputPointsPerM: 1200, outputPointsPerM: 4800,
                   officialInputYuanPerM: 4, officialOutputYuanPerM: 16),
        CloudModel(id: "deepseek-v4-pro", label: "DeepSeek V4 Pro",
                   note: "推理与代码最强，最贵。", isDefault: false,
                   inputPointsPerM: 1350, outputPointsPerM: 4050,
                   officialInputYuanPerM: 4.5, officialOutputYuanPerM: 13.5)
    ]

    private init() { loadCache() }

    /// 兜底名单的 id（供别处校验「这个模型 id 我们认不认」）。
    ///
    /// ⚠️ **非隔离**：`ConfigShare.apply` 在非隔离上下文里用它做白名单校验。
    nonisolated static var fallbackIDs: [String] { Self.fallback.map(\.id) }

    /// 「当前选中的模型 id」—— **非隔离**的静态存取器。
    ///
    /// ⚠️ 为什么单独拎出来：`AppSettings.llm` 与 `ConfigShare` 都要读它，
    ///    而它们不在 MainActor 上。放在这里（纯 UserDefaults 读写）就绕开了 actor 边界。
    private static let selectedKey = "aevis.cloudModel.selected"

    nonisolated static var selectedID: String {
        get { UserDefaults.standard.string(forKey: selectedKey) ?? DEFAULT_ID }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }

    /// 我们认识的模型 id：云端下发的 + 兜底的。
    /// ⚠️ 非隔离（`ConfigShare.apply` 要用）。
    nonisolated static var knownIDs: [String] {
        var ids = fallbackIDs
        if let cached = UserDefaults.standard.array(forKey: "aevis.cloudModels.v1.ids")
            as? [String] {
            for x in cached where !ids.contains(x) { ids.append(x) }
        }
        return ids
    }

    /// 默认模型 id（与后端 DEFAULT_MODEL 对齐）。
    nonisolated static let DEFAULT_ID = "deepseek-flash"

    /// 当前选中的模型 id（与后端默认一致）。
    ///
    /// 转发到**非隔离的静态存取器** —— 这样 `AppSettings.llm` / `ConfigShare`
    /// 在非隔离上下文里也能用同一个值（两边不会选出两个不同的模型）。
    var selectedID: String {
        get { Self.selectedID }
        set {
            // ⚠️ 以前这里只写 UserDefaults，不发变更通知。
            //    SettingsView 用的是 @ObservedObject，收不到 objectWillChange 就不会重算，
            //    界面上的选中圆点永远停在旧的一行 —— 用户看到的就是
            //    「点了没反应 / 模型切不了」。值其实写进去了，只是界面没刷新。
            guard newValue != Self.selectedID else { return }
            objectWillChange.send()
            Self.selectedID = newValue
        }
    }

    var selected: CloudModel? {
        models.first(where: { $0.id == selectedID })
            ?? Self.fallback.first(where: { $0.id == selectedID })
    }

    /// 按厂商分组后的列表（二级菜单用，默认全部收起）。
    ///
    /// 次序固定：DeepSeek 排第一 —— 它是默认模型所在的组，展开时最靠上。
    /// 其余按常见程度排，认不出来的「其他」垫底。
    var grouped: [CloudModelGroup] {
        let order = ["DeepSeek", "Claude", "Gemini", "GPT", "GLM",
                     "Kimi", "MiniMax", "Grok", "Qwen", "其他"]
        var bucket: [String: [CloudModel]] = [:]
        for m in models { bucket[m.vendor, default: []].append(m) }
        return order.compactMap { v in
            guard let list = bucket[v], !list.isEmpty else { return nil }
            return CloudModelGroup(vendor: v, models: list)
        }
    }

    /// 拉模型列表（带缓存与兜底）。
    func refresh(force: Bool = false) async {
        if !force, Date().timeIntervalSince(loadedAt) < ttl, !models.isEmpty {
            return
        }
        loading = true
        defer { loading = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: AevisHosts.llmModelsURL)!)
            // 后端返回 {code,data,msg} 信封
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let payload = (obj["data"] as? [String: Any]) ?? obj
            let list = (payload["models"] as? [[String: Any]]) ?? []
            let decoded = list.compactMap { row -> CloudModel? in
                guard let id = row["id"] as? String else { return nil }
                return CloudModel(
                    id: id,
                    label: (row["label"] as? String) ?? id,
                    note: (row["note"] as? String) ?? "",
                    isDefault: (row["default"] as? Bool) ?? false,
                    inputPointsPerM: (row["inputPointsPerM"] as? Double) ?? 0,
                    outputPointsPerM: (row["outputPointsPerM"] as? Double) ?? 0,
                    officialInputYuanPerM: (row["officialInputYuanPerM"] as? Double) ?? 0,
                    officialOutputYuanPerM: (row["officialOutputYuanPerM"] as? Double) ?? 0,
                    perCallPoints: (row["perCallPoints"] as? Double) ?? 0,
                    billing: (row["billing"] as? String) ?? "per_token"
                )
            }
            if !decoded.isEmpty {
                models = decoded
                loadedAt = Date()
                lastError = ""
                saveCache(decoded)
                // 顺手把「哪些模型现在离线」也拿一遍（失败就当全在线）
                await refreshStatus()
                return
            }
            lastError = "云端没返回可选模型"
        } catch {
            lastError = error.localizedDescription
        }
        // 拉失败 → 用缓存 / 兜底，别让用户卡在"没有模型可选"
        if models.isEmpty { models = Self.fallback }
    }

    /// 拉一次「哪些模型现在离线」（2026-11-12）。
    ///
    /// 数据源是后端的 `/v1/llm/status`，它读的是上游那个公开状态页 JSON
    /// （不需要 key、不花额度）。拿不到就保持空集合 —— 界面上全是绿点，
    /// 比"全部标灰、用户以为全挂了"要好。
    func refreshStatus() async {
        guard let url = URL(string: AevisHosts.llmStatusURL) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let payload = (obj["data"] as? [String: Any]) ?? obj
            let list = (payload["models"] as? [[String: Any]]) ?? []
            var off = Set<String>()
            for row in list {
                guard let id = row["model"] as? String else { continue }
                if (row["online"] as? Bool) == false {
                    off.insert(id.lowercased())
                }
            }
            offlineIDs = off
        } catch {
            // 状态拿不到不影响选模型
        }
    }

    private func saveCache(_ list: [CloudModel]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: cacheKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheStampKey)
        }
        // 另存一份纯 id 数组 —— 非隔离的 `knownIDs` 要用（它拿不到 @Published 的 models）
        UserDefaults.standard.set(list.map(\.id), forKey: cacheKey + ".ids")
    }

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let list = try? JSONDecoder().decode([CloudModel].self, from: data),
           !list.isEmpty {
            models = list
            // ⚠️ 用**落盘时间**，不是"现在"：否则每次启动都续命，
            //    后端改了名字这边永远看不到（2026-11-12 的 bug）。
            let stamp = UserDefaults.standard.double(forKey: cacheStampKey)
            loadedAt = stamp > 0 ? Date(timeIntervalSince1970: stamp) : .distantPast
        } else {
            models = Self.fallback
        }
    }
}
