import Foundation

/// 一次模型调用的完整参数快照。传值而不是传对象，避免跨线程访问设置。
struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String
}

/// 语音从哪儿来。
enum TTSMode: String, Codable, CaseIterable, Identifiable {
    case system
    case remote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "系统音色"
        case .remote: return "外部 API"
        }
    }
}

/// 一次语音合成的完整参数快照。
struct TTSConfig {
    var mode: TTSMode
    var baseURL: String
    var apiKey: String
    var model: String
    var voice: String
    /// 0.5 为正常语速；外接 API 时会映射成它的 speed 参数。
    var rate: Double
}

/// 全局设置。API Key 只进钥匙串，其余进 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let baseURL = "aevis.baseURL"
        static let model = "aevis.model"
        static let modelList = "aevis.modelList"
        static let speakerEnabled = "aevis.speakerEnabled"
        static let speechRate = "aevis.speechRate"
        static let ttsMode = "aevis.ttsMode"
        static let ttsBaseURL = "aevis.ttsBaseURL"
        static let ttsModel = "aevis.ttsModel"
        static let ttsVoice = "aevis.ttsVoice"
        static let ttsVoices = "aevis.ttsVoices"
        static let llmKeychain = "openai.apiKey"
        static let ttsKeychain = "tts.apiKey"
    }

    // MARK: - 模型接入

    /// 任意 OpenAI 兼容接口的根地址（不含 /chat/completions）。
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Key.baseURL) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Key.model) }
    }

    /// 从接口拉回来的模型清单，用来做下拉选择。
    @Published var modelList: [String] {
        didSet { UserDefaults.standard.set(modelList, forKey: Key.modelList) }
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Key.llmKeychain) }
    }

    // MARK: - 说话

    @Published var speakerEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerEnabled, forKey: Key.speakerEnabled) }
    }

    @Published var speechRate: Double {
        didSet { UserDefaults.standard.set(speechRate, forKey: Key.speechRate) }
    }

    @Published var ttsMode: TTSMode {
        didSet { UserDefaults.standard.set(ttsMode.rawValue, forKey: Key.ttsMode) }
    }

    /// 留空表示沿用模型接口地址。
    @Published var ttsBaseURL: String {
        didSet { UserDefaults.standard.set(ttsBaseURL, forKey: Key.ttsBaseURL) }
    }

    @Published var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: Key.ttsModel) }
    }

    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: Key.ttsVoice) }
    }

    /// 从接口拉回来的音色清单（也可能是内置兜底清单）。
    @Published var ttsVoices: [String] {
        didSet { UserDefaults.standard.set(ttsVoices, forKey: Key.ttsVoices) }
    }

    /// 留空表示沿用模型接口的 Key。
    @Published var ttsAPIKey: String {
        didSet { Keychain.set(ttsAPIKey, for: Key.ttsKeychain) }
    }

    private init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.deepseek.com/v1"
        model = defaults.string(forKey: Key.model) ?? "deepseek-chat"
        modelList = defaults.stringArray(forKey: Key.modelList) ?? []
        apiKey = Keychain.get(Key.llmKeychain) ?? ""
        speakerEnabled = defaults.object(forKey: Key.speakerEnabled) as? Bool ?? false
        speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? 0.48
        ttsMode = TTSMode(rawValue: defaults.string(forKey: Key.ttsMode) ?? "") ?? .system
        ttsBaseURL = defaults.string(forKey: Key.ttsBaseURL) ?? ""
        ttsModel = defaults.string(forKey: Key.ttsModel) ?? "tts-1"
        ttsVoice = defaults.string(forKey: Key.ttsVoice) ?? ""
        ttsVoices = defaults.stringArray(forKey: Key.ttsVoices) ?? []
        ttsAPIKey = Keychain.get(Key.ttsKeychain) ?? ""
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var llm: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// 语音参数快照。外接语音的地址与 Key 留空时自动沿用模型的那套，
    /// 这样大多数中转站不用重复填。
    var tts: TTSConfig {
        let url = ttsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ttsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return TTSConfig(
            mode: ttsMode,
            baseURL: url.isEmpty ? baseURL : url,
            apiKey: key.isEmpty ? apiKey : key,
            model: name.isEmpty ? "tts-1" : name,
            voice: ttsVoice,
            rate: speechRate
        )
    }
}
