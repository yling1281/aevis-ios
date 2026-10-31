import Foundation

/// 云端可选模型（由后端 `/v1/llm/models` 下发）。
///
/// ⚠️ 计价口径在后端（DeepSeek 官方价 × 1.5，1 元 = 200 积分），
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

    enum CodingKeys: String, CodingKey {
        case id, label, note
        case isDefault = "default"
        case inputPointsPerM, outputPointsPerM
        case officialInputYuanPerM, officialOutputYuanPerM
    }

    /// ⚠️ **必须显式写这个初始化器**。
    ///
    /// 一旦写了 `init(from decoder:)`，编译器就**不再自动合成**成员初始化器 ——
    /// 于是 `CloudModel(id:label:note:isDefault:...)` 这种写法会报
    /// 「extra arguments … missing argument for parameter 'from'」。
    /// 所以这里把全参初始化器补回来（兜底名单就是用它建的）。
    init(id: String, label: String, note: String, isDefault: Bool,
         inputPointsPerM: Double, outputPointsPerM: Double,
         officialInputYuanPerM: Double, officialOutputYuanPerM: Double) {
        self.id = id
        self.label = label
        self.note = note
        self.isDefault = isDefault
        self.inputPointsPerM = inputPointsPerM
        self.outputPointsPerM = outputPointsPerM
        self.officialInputYuanPerM = officialInputYuanPerM
        self.officialOutputYuanPerM = officialOutputYuanPerM
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
    }

    /// 「输入 1 元 ≈ 多少积分」这类提示用得上。
    var priceHint: String {
        String(format: "输入 %.0f 积分 / 百万字，输出 %.0f 积分 / 百万字",
               inputPointsPerM, outputPointsPerM)
    }
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

    private let cacheKey = "aevis.cloudModels.v1"
    private let ttl: TimeInterval = 6 * 3600

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
        set { Self.selectedID = newValue }
    }

    var selected: CloudModel? {
        models.first(where: { $0.id == selectedID })
            ?? Self.fallback.first(where: { $0.id == selectedID })
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
                    officialOutputYuanPerM: (row["officialOutputYuanPerM"] as? Double) ?? 0
                )
            }
            if !decoded.isEmpty {
                models = decoded
                loadedAt = Date()
                lastError = ""
                saveCache(decoded)
                return
            }
            lastError = "云端没返回可选模型"
        } catch {
            lastError = error.localizedDescription
        }
        // 拉失败 → 用缓存 / 兜底，别让用户卡在"没有模型可选"
        if models.isEmpty { models = Self.fallback }
    }

    private func saveCache(_ list: [CloudModel]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        // 另存一份纯 id 数组 —— 非隔离的 `knownIDs` 要用（它拿不到 @Published 的 models）
        UserDefaults.standard.set(list.map(\.id), forKey: cacheKey + ".ids")
    }

    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let list = try? JSONDecoder().decode([CloudModel].self, from: data),
           !list.isEmpty {
            models = list
            loadedAt = Date()   // 缓存当次有效，6 小时后再拉
        } else {
            models = Self.fallback
        }
    }
}
