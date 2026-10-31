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
    private static let fallback: [CloudModel] = [
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
    static var fallbackIDs: [String] { Self.fallback.map(\.id) }

    /// 当前选中的模型 id（与后端默认一致）。
    var selectedID: String {
        get {
            let saved = UserDefaults.standard.string(forKey: "aevis.cloudModel.selected")
            if let saved, models.contains(where: { $0.id == saved }) { return saved }
            if let saved, Self.fallback.contains(where: { $0.id == saved }) { return saved }
            return models.first(where: { $0.isDefault })?.id
                ?? Self.fallback.first?.id ?? "deepseek-flash"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "aevis.cloudModel.selected")
        }
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
