import Foundation
import SwiftUI

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

/// 聊天背景。默认给一个，但不锁死。
enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case aurora
    case plain
    case paper
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: return "光晕"
        case .plain: return "纯色"
        case .paper: return "纸感"
        case .custom: return "我的图片"
        }
    }
}

/// 全局设置。API Key 只进钥匙串，其余进 UserDefaults（图片走文件）。
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
        static let useGlass = "aevis.useGlass"
        static let simpleMode = "aevis.simpleMode"
        static let backgroundStyle = "aevis.backgroundStyle"
        static let accentIndex = "aevis.accentIndex"
        static let llmKeychain = "openai.apiKey"
        static let ttsKeychain = "tts.apiKey"
    }

    /// 主题色候选。用户挑一个，界面里所有强调色跟着变。
    static let accentPalette: [Color] = [
        Color(red: 0.42, green: 0.35, blue: 0.95),
        Color(red: 0.20, green: 0.48, blue: 0.96),
        Color(red: 0.13, green: 0.64, blue: 0.58),
        Color(red: 0.88, green: 0.32, blue: 0.52),
        Color(red: 0.92, green: 0.55, blue: 0.18),
        Color(red: 0.40, green: 0.62, blue: 0.20)
    ]

    static let accentNames = ["紫", "蓝", "青", "玫红", "橙", "绿"]

    // MARK: - 模型接入

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Key.baseURL) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Key.model) }
    }

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

    @Published var ttsBaseURL: String {
        didSet { UserDefaults.standard.set(ttsBaseURL, forKey: Key.ttsBaseURL) }
    }

    @Published var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: Key.ttsModel) }
    }

    @Published var ttsVoice: String {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: Key.ttsVoice) }
    }

    @Published var ttsVoices: [String] {
        didSet { UserDefaults.standard.set(ttsVoices, forKey: Key.ttsVoices) }
    }

    @Published var ttsAPIKey: String {
        didSet { Keychain.set(ttsAPIKey, for: Key.ttsKeychain) }
    }

    // MARK: - 外观

    /// 用不用液态玻璃。关掉就变纯色卡片。
    @Published var useGlass: Bool {
        didSet { UserDefaults.standard.set(useGlass, forKey: Key.useGlass) }
    }

    /// 简易模式：更大的字、更松的间距、不要花哨装饰。
    @Published var simpleMode: Bool {
        didSet { UserDefaults.standard.set(simpleMode, forKey: Key.simpleMode) }
    }

    @Published var backgroundStyle: BackgroundStyle {
        didSet { UserDefaults.standard.set(backgroundStyle.rawValue, forKey: Key.backgroundStyle) }
    }

    /// 自定义背景图（已压缩）。放文件，不放 UserDefaults。
    @Published var customBackgroundData: Data? {
        didSet {
            let url = Self.backgroundFileURL
            if let data = customBackgroundData {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @Published var accentIndex: Int {
        didSet { UserDefaults.standard.set(accentIndex, forKey: Key.accentIndex) }
    }

    private static var backgroundFileURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("aevis-background.img")
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
        useGlass = defaults.object(forKey: Key.useGlass) as? Bool ?? true
        simpleMode = defaults.object(forKey: Key.simpleMode) as? Bool ?? false
        backgroundStyle = BackgroundStyle(rawValue: defaults.string(forKey: Key.backgroundStyle) ?? "") ?? .aurora
        accentIndex = defaults.object(forKey: Key.accentIndex) as? Int ?? 0
        customBackgroundData = try? Data(contentsOf: Self.backgroundFileURL)
    }

    // MARK: - 派生

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accentColor: Color {
        let index = min(max(accentIndex, 0), Self.accentPalette.count - 1)
        return Self.accentPalette[index]
    }

    var llm: LLMConfig {
        LLMConfig(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// 语音参数快照。外接语音的地址与 Key 留空时自动沿用模型那套。
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
