import Foundation

/// 一次调用的完整参数快照。传值而不是传对象，避免跨线程访问设置。
struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String
}

/// 全局设置。API Key 只进钥匙串，其余进 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let baseURL = "aevis.baseURL"
        static let model = "aevis.model"
        static let speakerEnabled = "aevis.speakerEnabled"
        static let speechRate = "aevis.speechRate"
        static let keychainAccount = "openai.apiKey"
    }

    /// 任意 OpenAI 兼容接口的根地址（不含 /chat/completions）。
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Key.baseURL) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Key.model) }
    }

    /// 她回复完是否直接念出来。
    @Published var speakerEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerEnabled, forKey: Key.speakerEnabled) }
    }

    @Published var speechRate: Double {
        didSet { UserDefaults.standard.set(speechRate, forKey: Key.speechRate) }
    }

    @Published var apiKey: String {
        didSet { Keychain.set(apiKey, for: Key.keychainAccount) }
    }

    private init() {
        let defaults = UserDefaults.standard
        baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.deepseek.com/v1"
        model = defaults.string(forKey: Key.model) ?? "deepseek-chat"
        speakerEnabled = defaults.object(forKey: Key.speakerEnabled) as? Bool ?? false
        speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? 0.48
        apiKey = Keychain.get(Key.keychainAccount) ?? ""
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var llm: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }
}
