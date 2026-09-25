import Foundation
import SwiftUI

/// 一次模型调用的完整参数快照。传值而不是传对象，避免跨线程访问设置。
struct LLMConfig {
    var baseURL: String
    var apiKey: String
    var model: String
    /// 推理预算。不支持的接口会自动降级重试。
    var reasoning: ReasoningBudget = .off
    /// 每次带多少条历史。
    var contextLimit: Int = 40
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

/// 内置的 API 供应商预设。
/// **用户明确要求「API 你要提前加好」** —— 所以不许让他手填 URL。
/// 预设只是省事：地址和模型名都还能改，改完就当自定义。
enum ProviderPreset: String, CaseIterable, Identifiable {
    case deepseek
    case openai
    case gemini
    case doubao
    case qwen
    case kimi
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "ChatGPT"
        case .gemini: return "Google AI"
        case .doubao: return "豆包"
        case .qwen: return "千问"
        case .kimi: return "Kimi"
        case .custom: return "自定义"
        }
    }

    /// 都是 OpenAI 兼容的地址（这样一套调用逻辑能通吃）。
    var baseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .doubao: return "https://ark.cn-beijing.volces.com/api/v3"
        case .qwen: return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: return "https://api.moonshot.cn/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.0-flash"
        case .doubao: return ""
        case .qwen: return "qwen-plus"
        case .kimi: return "moonshot-v1-8k"
        case .custom: return ""
        }
    }

    /// 拿 Key 的地方，直接写给用户看。
    var keyHint: String {
        switch self {
        case .deepseek: return "platform.deepseek.com"
        case .openai: return "platform.openai.com"
        case .gemini: return "aistudio.google.com"
        case .doubao: return "火山方舟控制台（注意要填接入点 ID 当模型名）"
        case .qwen: return "阿里云百炼控制台"
        case .kimi: return "platform.moonshot.cn"
        case .custom: return "你自己的中转站或自建服务"
        }
    }
}

/// 推理预算。很多模型支持「想多久」这个档位，用户要能自己定。
enum ReasoningBudget: String, CaseIterable, Identifiable {
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        }
    }

    /// 传给接口的值。关闭时**不传这个字段** ——
    /// 有些模型不认它，传了反而报错。
    var parameter: String? {
        self == .off ? nil : rawValue
    }

    var explanation: String {
        switch self {
        case .off: return "不额外思考，回得最快，适合闲聊"
        case .low: return "稍微想一下，速度快"
        case .medium: return "平衡"
        case .high: return "想得最久，适合复杂问题，也更慢更贵"
        }
    }
}

/// 一个搜索源。用 `{q}` 占位关键词。
struct SearchSource: Codable, Identifiable, Hashable {
    var name: String
    var template: String

    var id: String { name }

    func url(for keyword: String) -> URL? {
        let encoded = keyword.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        ) ?? keyword
        return URL(string: template.replacingOccurrences(of: "{q}", with: encoded))
    }

    /// 内置几个。**必应是默认**（用户明确要求）。
    static let builtIn: [SearchSource] = [
        SearchSource(name: "必应", template: "https://www.bing.com/search?q={q}&setlang=zh-CN"),
        SearchSource(name: "百度", template: "https://www.baidu.com/s?wd={q}"),
        SearchSource(name: "DuckDuckGo", template: "https://duckduckgo.com/html/?q={q}")
    ]
}

/// 玻璃材质四档。用户要能自己挑，所以不做成写死的。
enum GlassStyle: String, CaseIterable, Identifiable {
    case standard
    case clear
    case frosted
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "标准"
        case .clear: return "清透"
        case .frosted: return "磨砂"
        case .off: return "关闭"
        }
    }

    var explanation: String {
        switch self {
        case .standard: return "系统默认的液态玻璃"
        case .clear: return "更透更亮，背景看得更清楚"
        case .frosted: return "更实的模糊，字最清楚"
        case .off: return "不要玻璃，用纯色卡片"
        }
    }
}

/// 气泡长什么样。**两侧各选一个** ——
/// 用户原话：「AI 的气泡也要改」「对方的气泡也能归我改」。
enum BubbleStyle: String, Codable, CaseIterable, Identifiable {
    case solid
    case glass
    case gradient
    case outline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid: return "实心"
        case .glass: return "玻璃"
        case .gradient: return "渐变"
        case .outline: return "描边"
        }
    }

    var explanation: String {
        switch self {
        case .solid: return "一整块颜色，最清晰"
        case .glass: return "半透明材质，能透出背景"
        case .gradient: return "从深到浅，有一点层次"
        case .outline: return "只有一圈边，里面是空的"
        }
    }
}

/// 一侧气泡的完整外观。两侧各存一份，互不影响。
struct BubbleLook: Codable, Equatable {
    var style: BubbleStyle = .solid

    /// 颜色。-1 表示「跟随主题色」，其余是 `AppSettings.bubblePalette` 的下标。
    var colorIndex: Int = -1

    /// 在全局圆角之上再乘一次，让两侧气泡能各圆各的。
    var cornerScale: Double = 1.0
}

/// 全局设置。API Key 只进钥匙串，其余进 UserDefaults（图片走文件）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let baseURL = "aevis.baseURL"
        static let model = "aevis.model"
        static let modelList = "aevis.modelList"
        static let providerPreset = "aevis.providerPreset"
        static let reasoningBudget = "aevis.reasoningBudget"
        static let contextLimit = "aevis.contextLimit"
        static let searchSources = "aevis.searchSources"
        static let activeSearchSource = "aevis.activeSearchSource"
        static let autoTestOnLaunch = "aevis.autoTestOnLaunch"
        static let speakerEnabled = "aevis.speakerEnabled"
        static let speechRate = "aevis.speechRate"
        static let ttsMode = "aevis.ttsMode"
        static let ttsBaseURL = "aevis.ttsBaseURL"
        static let ttsModel = "aevis.ttsModel"
        static let ttsVoice = "aevis.ttsVoice"
        static let ttsVoices = "aevis.ttsVoices"
        static let useGlass = "aevis.useGlass"
        static let glassStyle = "aevis.glassStyle"
        static let myBubble = "aevis.myBubble"
        static let aiBubble = "aevis.aiBubble"
        static let showMyAvatar = "aevis.showMyAvatar"
        static let showAiAvatar = "aevis.showAiAvatar"
        static let cornerScale = "aevis.cornerScale"
        static let tintStrength = "aevis.tintStrength"
        static let fontColorIndex = "aevis.fontColorIndex"
        static let simpleMode = "aevis.simpleMode"
        static let backgroundStyle = "aevis.backgroundStyle"
        static let backgroundDim = "aevis.backgroundDim"
        static let accentIndex = "aevis.accentIndex"
        static let proactiveEnabled = "aevis.proactiveEnabled"
        static let fixedTimesEnabled = "aevis.fixedTimesEnabled"
        static let fixedTimes = "aevis.fixedTimes"
        static let randomEnabled = "aevis.randomEnabled"
        static let randomPerDay = "aevis.randomPerDay"
        static let proactiveLines = "aevis.proactiveLines"
        static let barkEnabled = "aevis.barkEnabled"
        static let barkURL = "aevis.barkURL"
        static let memoryEnabled = "aevis.memoryEnabled"
        static let memoryExtractEvery = "aevis.memoryExtractEvery"
        static let memoryInjectEnabled = "aevis.memoryInjectEnabled"
        static let momentsEnabled = "aevis.momentsEnabled"
        static let momentsPerDay = "aevis.momentsPerDay"
        static let momentAutoReact = "aevis.momentAutoReact"
        static let momentLikeMine = "aevis.momentLikeMine"
        static let momentMaxComments = "aevis.momentMaxComments"
        static let momentAutoReply = "aevis.momentAutoReply"
        static let momentMaxReplies = "aevis.momentMaxReplies"
        static let momentDMEnabled = "aevis.momentDMEnabled"
        static let momentDMChance = "aevis.momentDMChance"
        static let douyinConfirmRisky = "aevis.douyinConfirmRisky"
        static let companionEnabled = "aevis.companionEnabled"
        static let companionInterval = "aevis.companionInterval"
        static let shortcutName = "aevis.shortcutName"
        /// 打开 App 先进哪个 tab（通讯录 / 聊天 / 发现 / 我）。
        static let defaultTab = "aevis.defaultTab"
        static let lockShortcutName = "aevis.lockShortcutName"
        static let screenTimeShortcutName = "aevis.screenTimeShortcutName"
        static let listenTogetherMode = "aevis.listenTogetherMode"
        static let neteaseCookieKeychain = "netease.cookie"
        static let douyinCookieKeychain = "douyin.cookie"
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

    /// 文字颜色候选。第一个是「跟随系统」。
    static let fontColorPalette: [Color] = [
        Color.primary,
        Color(red: 0.10, green: 0.11, blue: 0.14),
        Color(red: 0.26, green: 0.20, blue: 0.46),
        Color(red: 0.10, green: 0.30, blue: 0.46),
        Color(red: 0.42, green: 0.14, blue: 0.22),
        Color(red: 0.14, green: 0.33, blue: 0.19)
    ]

    static let fontColorNames = ["默认", "墨黑", "深紫", "深蓝", "酒红", "墨绿"]

    /// 气泡可选的颜色。第一个是中性灰，后面跟着六个主题色板。
    /// （下标 -1 另有一档「跟随主题色」，不在这个数组里。）
    static let bubblePalette: [Color] = [
        Color(red: 0.55, green: 0.56, blue: 0.62)
    ] + accentPalette

    static let bubbleColorNames = ["中性灰", "紫", "蓝", "青", "玫红", "橙", "绿"]

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

    /// 当前用的是哪个预设供应商。切预设会自动填地址和模型名。
    @Published var providerPreset: ProviderPreset {
        didSet { UserDefaults.standard.set(providerPreset.rawValue, forKey: Key.providerPreset) }
    }

    /// 推理预算：关闭 / LOW / MEDIUM / HIGH。
    @Published var reasoningBudget: ReasoningBudget {
        didSet { UserDefaults.standard.set(reasoningBudget.rawValue, forKey: Key.reasoningBudget) }
    }

    /// 每次带多少条历史给模型。带太多会又慢又贵，太少她会失忆。
    @Published var contextLimit: Int {
        didSet { UserDefaults.standard.set(contextLimit, forKey: Key.contextLimit) }
    }

    /// 搜索源列表。用户能加能删，**必应是默认第一个**。
    @Published var searchSources: [SearchSource] {
        didSet {
            if let data = try? JSONEncoder().encode(searchSources) {
                UserDefaults.standard.set(data, forKey: Key.searchSources)
            }
        }
    }

    @Published var activeSearchSource: String {
        didSet { UserDefaults.standard.set(activeSearchSource, forKey: Key.activeSearchSource) }
    }

    /// 启动时自动测一次连接，不通就直接在聊天页提示。
    @Published var autoTestOnLaunch: Bool {
        didSet { UserDefaults.standard.set(autoTestOnLaunch, forKey: Key.autoTestOnLaunch) }
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

    /// 玻璃的材质。和 useGlass 配合：useGlass 关掉时这个值保留着，下次开还用它。
    @Published var glassStyle: GlassStyle {
        didSet { UserDefaults.standard.set(glassStyle.rawValue, forKey: Key.glassStyle) }
    }

    /// 我这一侧的气泡长什么样。
    @Published var myBubble: BubbleLook {
        didSet { Self.store(myBubble, forKey: Key.myBubble) }
    }

    /// TA 那一侧的气泡长什么样。**和我的分开** —— 各改各的。
    @Published var aiBubble: BubbleLook {
        didSet { Self.store(aiBubble, forKey: Key.aiBubble) }
    }

    /// 聊天里显不显示我自己的头像。
    @Published var showMyAvatar: Bool {
        didSet { UserDefaults.standard.set(showMyAvatar, forKey: Key.showMyAvatar) }
    }

    /// 聊天里显不显示 TA 的头像。
    @Published var showAiAvatar: Bool {
        didSet { UserDefaults.standard.set(showAiAvatar, forKey: Key.showAiAvatar) }
    }

    /// 圆角系数。1.0 是默认，可大可小。
    @Published var cornerScale: Double {
        didSet { UserDefaults.standard.set(cornerScale, forKey: Key.cornerScale) }
    }

    /// 主题色的上色浓度。0 = 几乎不着色，1 = 很浓。
    @Published var tintStrength: Double {
        didSet { UserDefaults.standard.set(tintStrength, forKey: Key.tintStrength) }
    }

    /// 文字颜色的选择，0 表示跟随系统。
    @Published var fontColorIndex: Int {
        didSet { UserDefaults.standard.set(fontColorIndex, forKey: Key.fontColorIndex) }
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

    /// 自定义背景图上压的那层遮罩有多重。0 = 不压。压太重会把图糊掉，所以默认很轻。
    @Published var backgroundDim: Double {
        didSet { UserDefaults.standard.set(backgroundDim, forKey: Key.backgroundDim) }
    }

    // MARK: - 主动消息

    /// 总开关。关掉之后不再排任何主动消息。
    @Published var proactiveEnabled: Bool {
        didSet { UserDefaults.standard.set(proactiveEnabled, forKey: Key.proactiveEnabled) }
    }

    /// 定时发消息开关。
    @Published var fixedTimesEnabled: Bool {
        didSet { UserDefaults.standard.set(fixedTimesEnabled, forKey: Key.fixedTimesEnabled) }
    }

    /// 定时的时间点，格式 "HH:mm"。
    @Published var fixedTimes: [String] {
        didSet { UserDefaults.standard.set(fixedTimes, forKey: Key.fixedTimes) }
    }

    /// 不定时发消息开关。
    @Published var randomEnabled: Bool {
        didSet { UserDefaults.standard.set(randomEnabled, forKey: Key.randomEnabled) }
    }

    /// 不定时每天几条。
    @Published var randomPerDay: Int {
        didSet { UserDefaults.standard.set(randomPerDay, forKey: Key.randomPerDay) }
    }

    /// 提前写好的一批「她会主动说的话」。
    @Published var proactiveLines: [String] {
        didSet { UserDefaults.standard.set(proactiveLines, forKey: Key.proactiveLines) }
    }

    @Published var barkEnabled: Bool {
        didSet { UserDefaults.standard.set(barkEnabled, forKey: Key.barkEnabled) }
    }

    @Published var barkURL: String {
        didSet { UserDefaults.standard.set(barkURL, forKey: Key.barkURL) }
    }

    // MARK: - 长期记忆

    /// 开着的话，聊够一段就自动让她提炼一次。
    @Published var memoryEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: Key.memoryEnabled) }
    }

    /// 每攒够多少条新消息提炼一次。
    @Published var memoryExtractEvery: Int {
        didSet { UserDefaults.standard.set(memoryExtractEvery, forKey: Key.memoryExtractEvery) }
    }

    /// 要不要把记忆带进每次对话。关掉之后记忆还在，只是她这次不提。
    @Published var memoryInjectEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryInjectEnabled, forKey: Key.memoryInjectEnabled) }
    }

    // MARK: - 朋友圈

    /// 让她自己发朋友圈。
    @Published var momentsEnabled: Bool {
        didSet { UserDefaults.standard.set(momentsEnabled, forKey: Key.momentsEnabled) }
    }

    /// 一天大概几条。
    @Published var momentsPerDay: Int {
        didSet { UserDefaults.standard.set(momentsPerDay, forKey: Key.momentsPerDay) }
    }

    /// 我发完动态之后，她自动来互动（点赞 / 评论）。
    @Published var momentAutoReact: Bool {
        didSet { UserDefaults.standard.set(momentAutoReact, forKey: Key.momentAutoReact) }
    }

    /// 她会给我点赞吗。
    @Published var momentLikeMine: Bool {
        didSet { UserDefaults.standard.set(momentLikeMine, forKey: Key.momentLikeMine) }
    }

    /// 她最多在我一条动态下评论几条。
    @Published var momentMaxComments: Int {
        didSet { UserDefaults.standard.set(momentMaxComments, forKey: Key.momentMaxComments) }
    }

    /// 我在她动态下评论之后，她自动回一句。
    @Published var momentAutoReply: Bool {
        didSet { UserDefaults.standard.set(momentAutoReply, forKey: Key.momentAutoReply) }
    }

    /// 她最多回复几条 —— 到上限就不再回了，免得没完没了。
    @Published var momentMaxReplies: Int {
        didSet { UserDefaults.standard.set(momentMaxReplies, forKey: Key.momentMaxReplies) }
    }

    /// 她刷到我动态之后，有时候会**直接私信**我，而不是只在评论区说。
    @Published var momentDMEnabled: Bool {
        didSet { UserDefaults.standard.set(momentDMEnabled, forKey: Key.momentDMEnabled) }
    }

    /// 私信的概率。0.4 = 大概十次里有四次她会直接来找我。
    @Published var momentDMChance: Double {
        didSet { UserDefaults.standard.set(momentDMChance, forKey: Key.momentDMChance) }
    }

    // MARK: - 抖音（写操作还没接，但这个开关先备好）

    /// 高危写操作（评论、发布、取关这类）要不要二次确认。默认开。
    @Published var douyinConfirmRisky: Bool {
        didSet { UserDefaults.standard.set(douyinConfirmRisky, forKey: Key.douyinConfirmRisky) }
    }

    // MARK: - 录屏陪伴

    /// 让她看你的屏幕（只在本机认文字，不传画面）。
    @Published var companionEnabled: Bool {
        didSet { UserDefaults.standard.set(companionEnabled, forKey: Key.companionEnabled) }
    }

    /// 每隔多少秒看一次。
    @Published var companionInterval: Double {
        didSet { UserDefaults.standard.set(companionInterval, forKey: Key.companionInterval) }
    }

    // MARK: - 系统桥接

    /// 用户自己做好的快捷指令名字（锁屏、开 App 这类）。
    @Published var shortcutName: String {
        didSet { UserDefaults.standard.set(shortcutName, forKey: Key.shortcutName) }
    }

    /// 「锁屏」快捷指令的名字 —— iOS 不让 App 锁屏，只能靠它。
    @Published var lockShortcutName: String {
        didSet { UserDefaults.standard.set(lockShortcutName, forKey: Key.lockShortcutName) }
    }

    /// 打开 App 先进哪个 tab。存的是 `MainTab` 的 rawValue。
    /// 出厂是「通讯录」—— 用户要求「进去就是联系人」。
    @Published var defaultTab: String {
        didSet { UserDefaults.standard.set(defaultTab, forKey: Key.defaultTab) }
    }

    /// 「屏幕使用时间」快捷指令的名字 —— 数据靠它跑完用 aevis:// 发回来。
    @Published var screenTimeShortcutName: String {
        didSet { UserDefaults.standard.set(screenTimeShortcutName, forKey: Key.screenTimeShortcutName) }
    }

    /// 上次用的一起听形态。
    @Published var listenTogetherMode: String {
        didSet { UserDefaults.standard.set(listenTogetherMode, forKey: Key.listenTogetherMode) }
    }

    // MARK: - 第三方登录凭据

    /// 网易云的 Cookie。**只进钥匙串**，和 API Key 一个待遇。
    @Published var neteaseCookie: String {
        didSet { Keychain.set(neteaseCookie, for: Key.neteaseCookieKeychain) }
    }

    /// 抖音的 Cookie。同理。
    @Published var douyinCookie: String {
        didSet { Keychain.set(douyinCookie, for: Key.douyinCookieKeychain) }
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
        providerPreset = ProviderPreset(rawValue: defaults.string(forKey: Key.providerPreset) ?? "") ?? .deepseek
        reasoningBudget = ReasoningBudget(rawValue: defaults.string(forKey: Key.reasoningBudget) ?? "") ?? .off
        contextLimit = defaults.object(forKey: Key.contextLimit) as? Int ?? 40
        autoTestOnLaunch = defaults.object(forKey: Key.autoTestOnLaunch) as? Bool ?? true
        if let data = defaults.data(forKey: Key.searchSources),
           let decoded = try? JSONDecoder().decode([SearchSource].self, from: data),
           !decoded.isEmpty {
            searchSources = decoded
        } else {
            searchSources = SearchSource.builtIn
        }
        activeSearchSource = defaults.string(forKey: Key.activeSearchSource) ?? (SearchSource.builtIn.first?.name ?? "必应")
        speakerEnabled = defaults.object(forKey: Key.speakerEnabled) as? Bool ?? false
        speechRate = defaults.object(forKey: Key.speechRate) as? Double ?? 0.48
        ttsMode = TTSMode(rawValue: defaults.string(forKey: Key.ttsMode) ?? "") ?? .system
        ttsBaseURL = defaults.string(forKey: Key.ttsBaseURL) ?? ""
        ttsModel = defaults.string(forKey: Key.ttsModel) ?? "tts-1"
        ttsVoice = defaults.string(forKey: Key.ttsVoice) ?? ""
        ttsVoices = defaults.stringArray(forKey: Key.ttsVoices) ?? []
        ttsAPIKey = Keychain.get(Key.ttsKeychain) ?? ""
        useGlass = defaults.object(forKey: Key.useGlass) as? Bool ?? true
        glassStyle = GlassStyle(rawValue: defaults.string(forKey: Key.glassStyle) ?? "") ?? .standard
        // 出厂状态：我的气泡实心跟着主题色；她的气泡玻璃。都能改。
        myBubble = Self.loadLook(forKey: Key.myBubble) ?? BubbleLook(style: .solid, colorIndex: -1)
        aiBubble = Self.loadLook(forKey: Key.aiBubble) ?? BubbleLook(style: .glass, colorIndex: -1)
        showMyAvatar = defaults.object(forKey: Key.showMyAvatar) as? Bool ?? true
        showAiAvatar = defaults.object(forKey: Key.showAiAvatar) as? Bool ?? true
        cornerScale = defaults.object(forKey: Key.cornerScale) as? Double ?? 1.0
        tintStrength = defaults.object(forKey: Key.tintStrength) as? Double ?? 1.0
        fontColorIndex = defaults.object(forKey: Key.fontColorIndex) as? Int ?? 0
        simpleMode = defaults.object(forKey: Key.simpleMode) as? Bool ?? false
        backgroundStyle = BackgroundStyle(rawValue: defaults.string(forKey: Key.backgroundStyle) ?? "") ?? .aurora
        backgroundDim = defaults.object(forKey: Key.backgroundDim) as? Double ?? 0.12
        accentIndex = defaults.object(forKey: Key.accentIndex) as? Int ?? 0
        proactiveEnabled = defaults.object(forKey: Key.proactiveEnabled) as? Bool ?? false
        fixedTimesEnabled = defaults.object(forKey: Key.fixedTimesEnabled) as? Bool ?? false
        fixedTimes = defaults.stringArray(forKey: Key.fixedTimes) ?? ["09:00", "13:30", "22:30"]
        randomEnabled = defaults.object(forKey: Key.randomEnabled) as? Bool ?? false
        randomPerDay = defaults.object(forKey: Key.randomPerDay) as? Int ?? 2
        proactiveLines = defaults.stringArray(forKey: Key.proactiveLines) ?? []
        barkEnabled = defaults.object(forKey: Key.barkEnabled) as? Bool ?? false
        barkURL = defaults.string(forKey: Key.barkURL) ?? ""
        memoryEnabled = defaults.object(forKey: Key.memoryEnabled) as? Bool ?? true
        memoryExtractEvery = defaults.object(forKey: Key.memoryExtractEvery) as? Int ?? 12
        memoryInjectEnabled = defaults.object(forKey: Key.memoryInjectEnabled) as? Bool ?? true
        momentsEnabled = defaults.object(forKey: Key.momentsEnabled) as? Bool ?? true
        momentsPerDay = defaults.object(forKey: Key.momentsPerDay) as? Int ?? 2
        momentAutoReact = defaults.object(forKey: Key.momentAutoReact) as? Bool ?? true
        momentLikeMine = defaults.object(forKey: Key.momentLikeMine) as? Bool ?? true
        momentMaxComments = defaults.object(forKey: Key.momentMaxComments) as? Int ?? 1
        momentAutoReply = defaults.object(forKey: Key.momentAutoReply) as? Bool ?? true
        momentMaxReplies = defaults.object(forKey: Key.momentMaxReplies) as? Int ?? 1
        momentDMEnabled = defaults.object(forKey: Key.momentDMEnabled) as? Bool ?? true
        momentDMChance = defaults.object(forKey: Key.momentDMChance) as? Double ?? 0.4
        douyinConfirmRisky = defaults.object(forKey: Key.douyinConfirmRisky) as? Bool ?? true
        companionEnabled = defaults.object(forKey: Key.companionEnabled) as? Bool ?? false
        companionInterval = defaults.object(forKey: Key.companionInterval) as? Double ?? 20
        shortcutName = defaults.string(forKey: Key.shortcutName) ?? ""
        defaultTab = defaults.string(forKey: Key.defaultTab) ?? "contacts"
        lockShortcutName = defaults.string(forKey: Key.lockShortcutName) ?? ""
        screenTimeShortcutName = defaults.string(forKey: Key.screenTimeShortcutName) ?? ""
        listenTogetherMode = defaults.string(forKey: Key.listenTogetherMode) ?? ListenTogetherMode.sync.rawValue
        neteaseCookie = Keychain.get(Key.neteaseCookieKeychain) ?? ""
        douyinCookie = Keychain.get(Key.douyinCookieKeychain) ?? ""
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

    /// 正文文字的颜色。用户挑的那个。
    var fontColor: Color {
        let index = min(max(fontColorIndex, 0), Self.fontColorPalette.count - 1)
        return Self.fontColorPalette[index]
    }

    /// 一侧气泡该用哪个颜色。colorIndex 为负就跟随主题色。
    func bubbleColor(_ look: BubbleLook) -> Color {
        guard look.colorIndex >= 0 else { return accentColor }
        let index = min(look.colorIndex, Self.bubblePalette.count - 1)
        return Self.bubblePalette[index]
    }

    /// 给人看的颜色名，界面上标一下当前选的是哪个。
    func bubbleColorName(_ look: BubbleLook) -> String {
        guard look.colorIndex >= 0 else { return "跟随主题色" }
        let index = min(look.colorIndex, Self.bubbleColorNames.count - 1)
        return Self.bubbleColorNames[index]
    }

    /// 把一套气泡外观写进 UserDefaults。
    private static func store(_ look: BubbleLook, forKey key: String) {
        guard let data = try? JSONEncoder().encode(look) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadLook(forKey key: String) -> BubbleLook? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BubbleLook.self, from: data)
    }

    var llm: LLMConfig {
        LLMConfig(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            reasoning: reasoningBudget,
            contextLimit: contextLimit
        )
    }

    /// 语音参数快照。外接语音的地址与 Key 留空时自动沿用模型那套，
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
