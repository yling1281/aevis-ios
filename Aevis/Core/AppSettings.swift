import CoreImage
import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

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
        /// 界面密度（0/1/2）与「主题色跟着头像走」
        static let densityIndex = "aevis.densityIndex"
        static let dynamicAccent = "aevis.dynamicAccent"
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
        // ——— 朋友圈个性化 ———
        static let momentStylePrompt = "aevis.momentStylePrompt"
        static let momentImageMode = "aevis.momentImageMode"
        static let momentMorningWeight = "aevis.momentMorningWeight"
        static let momentNoonWeight = "aevis.momentNoonWeight"
        static let momentEveningWeight = "aevis.momentEveningWeight"
        static let momentNightWeight = "aevis.momentNightWeight"
        static let momentFontScale = "aevis.momentFontScale"
        static let momentDensityIndex = "aevis.momentDensityIndex"
        static let momentTimeStyle = "aevis.momentTimeStyle"
        static let momentCorner = "aevis.momentCorner"
        static let douyinConfirmRisky = "aevis.douyinConfirmRisky"
        static let companionEnabled = "aevis.companionEnabled"
        static let companionInterval = "aevis.companionInterval"
        static let shortcutName = "aevis.shortcutName"
        /// 打开 App 先进哪个 tab（通讯录 / 聊天 / 发现 / 我）。
        static let defaultTab = "aevis.defaultTab"
        static let lockShortcutName = "aevis.lockShortcutName"
        static let screenTimeShortcutName = "aevis.screenTimeShortcutName"
        static let listenTogetherMode = "aevis.listenTogetherMode"
        /// 放歌就自动一起听（出厂开）
        static let listenTogetherAutoStart = "aevis.listenTogetherAutoStart"
        /// QQ 桥接：总开关 / 那个 OneBot 服务的地址 / 允不允许替用户发消息
        static let qqBridgeEnabled = "aevis.qqBridge.enabled"
        static let qqBridgeURL = "aevis.qqBridge.url"
        static let qqBridgeCanSend = "aevis.qqBridge.canSend"
        /// QQ 官方机器人
        static let qqBotEnabled = "aevis.qqBot.enabled"
        static let qqBotAppID = "aevis.qqBot.appID"
        static let qqBotSandbox = "aevis.qqBot.sandbox"
        static let qqBotKeepAlive = "aevis.qqBot.keepAlive"
        /// 网易云走哪条通道：`plain`（明文，默认）/ `weapi`（加密）。
        static let neteaseChannel = "aevis.netease.channel"
        static let neteaseCookieKeychain = "netease.cookie"
        static let douyinCookieKeychain = "douyin.cookie"
        /// QQ 桥接（OneBot）的 Access Token
        static let qqBridgeTokenKeychain = "qq.bridge.token"
        /// 账号登录后的 token
        static let accountTokenKeychain = "aevis.account.token"
        /// QQ 官方机器人的 AppSecret
        static let qqBotSecretKeychain = "aevis.qqBot.secret"
        static let qqBotCodeEnabled = "aevis.qqBotCode.enabled"
        static let qqBotCodeKeyword = "aevis.qqBotCode.keyword"
        static let qqBotCodeKeyKeychain = "aevis.qqBotCode.key"
        static let qqBotCodeGroups = "aevis.qqBotCode.groups"
        static let accountServerURL = "aevis.account.serverURL"
        static let accountExpiresAt = "aevis.account.expiresAt"
        static let llmKeychain = "openai.apiKey"
        static let ttsKeychain = "tts.apiKey"
        static let baiduPanAppKey = "baidu.pan.appKey"
        static let baiduPanSecretKey = "baidu.pan.secretKey"
        static let baiduPanToken = "baidu.pan.token"
        static let baiduPanRefreshToken = "baidu.pan.refreshToken"
        /// 授权完成后百度往哪跳。填 `oob` 就是「把授权码显示在页面上」。
        static let baiduPanRedirect = "aevis.baiduPan.redirect"
        /// 通行证的到期时刻（秒）。到点前用 refresh_token 悄悄续，不让用户重授权。
        static let baiduPanExpiresAt = "aevis.baiduPan.expiresAt"
        /// 最近一次授权/续期失败的原文。界面上要显示出来 ——
        /// 光说一句"授权失败"用户和我都没法判断是回调不合法还是 SecretKey 错了。
        static let baiduPanLastError = "aevis.baiduPan.lastError"
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

    /// 界面密度（0 紧凑 / 1 标准 / 2 宽松）。只改间距，不改字号。
    @Published var densityIndex: Int {
        didSet { UserDefaults.standard.set(densityIndex, forKey: Key.densityIndex) }
    }

    /// 主题色跟着当前联系人的头像走。
    /// 开关一开，`avatarTint` 里那份从图里取出来的颜色就接管 `accentColor`。
    @Published var dynamicAccent: Bool {
        didSet {
            UserDefaults.standard.set(dynamicAccent, forKey: Key.dynamicAccent)
            if !dynamicAccent { avatarTint = nil }
        }
    }

    /// 从头像上取出来的主色。**只在头像变化时算一次**（见 `refreshAvatarTint`）。
    @Published private(set) var avatarTint: Color?

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

    // MARK: - 朋友圈个性化（2026-09-25 用户要求「能自定义的都自定义」）

    /// 她的朋友圈风格。用户写一段（例如「爱发吃的和猫，语气懒懒的，偶尔发牢骚」），
    /// 会拼进生成动态的指令里。**留空就不干预**，模型自由发挥。
    @Published var momentStylePrompt: String {
        didSet { UserDefaults.standard.set(momentStylePrompt, forKey: Key.momentStylePrompt) }
    }

    /// 她发动态带不带图：
    ///   `none`    —— 只发文字
    ///   `library` —— 从「她的图库」里挑一张（图库是**用户自己往里放的**）
    /// ⚠️ 我们没法凭空给她生成照片。与其假装能，不如让她从你给的图里挑。
    @Published var momentImageMode: String {
        didSet { UserDefaults.standard.set(momentImageMode, forKey: Key.momentImageMode) }
    }

    /// 一天四个时段的偏好（0–100，早/午/晚/深夜）。
    /// 不是百分比 —— 只按**相对比例**算，所以四个都填 50 和都填 100 效果一样。
    /// 全填 0 = 不按时段干预，回到原来的「平均间隔」。
    @Published var momentMorningWeight: Int {
        didSet { UserDefaults.standard.set(momentMorningWeight, forKey: Key.momentMorningWeight) }
    }

    @Published var momentNoonWeight: Int {
        didSet { UserDefaults.standard.set(momentNoonWeight, forKey: Key.momentNoonWeight) }
    }

    @Published var momentEveningWeight: Int {
        didSet { UserDefaults.standard.set(momentEveningWeight, forKey: Key.momentEveningWeight) }
    }

    @Published var momentNightWeight: Int {
        didSet { UserDefaults.standard.set(momentNightWeight, forKey: Key.momentNightWeight) }
    }

    // ——— 朋友圈界面 ———

    /// 字号缩放。0.9 小 / 1.0 标准 / 1.15 大。
    @Published var momentFontScale: Double {
        didSet { UserDefaults.standard.set(momentFontScale, forKey: Key.momentFontScale) }
    }

    /// 卡片疏密：0 紧凑 / 1 标准 / 2 宽松。
    @Published var momentDensityIndex: Int {
        didSet { UserDefaults.standard.set(momentDensityIndex, forKey: Key.momentDensityIndex) }
    }

    /// 时间怎么显示：`relative` 三分钟前 / `clock` 21:04。
    @Published var momentTimeStyle: String {
        didSet { UserDefaults.standard.set(momentTimeStyle, forKey: Key.momentTimeStyle) }
    }

    /// 卡片圆角。
    @Published var momentCorner: Double {
        didSet { UserDefaults.standard.set(momentCorner, forKey: Key.momentCorner) }
    }

    static let momentWeightNames = ["早上 5–11", "中午 11–17", "晚上 17–22", "深夜 22–5"]

    /// 某个钟点落在哪个时段。
    static func momentBucket(ofHour hour: Int) -> Int {
        switch hour {
        case 5..<11: return 0
        case 11..<17: return 1
        case 17..<22: return 2
        default: return 3
        }
    }

    /// 当前时段的相对权重。1.0 = 刚好平均；2.0 = 这个时段她勤快一倍；
    /// 0 = 这个点她不发（调用方据此直接跳过）。
    var momentCurrentWeight: Double {
        let weights = [momentMorningWeight, momentNoonWeight,
                       momentEveningWeight, momentNightWeight]
        let total = weights.reduce(0, +)
        // 全填 0 → 不干预
        guard total > 0 else { return 1 }
        let hour = Calendar.current.component(.hour, from: Date())
        let weight = weights[Self.momentBucket(ofHour: hour)]
        guard weight > 0 else { return 0 }
        return Double(weight) / (Double(total) / 4.0)
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

    /// 在 App 里放歌时，**自动开始一起听**。
    ///
    /// 用户的原话：「在 App 内放音乐的话，默认一起听。」
    /// 出厂是开的 —— 但**这是个开关**，不想让她插嘴的人可以关掉。
    @Published var listenTogetherAutoStart: Bool {
        didSet { UserDefaults.standard.set(listenTogetherAutoStart, forKey: Key.listenTogetherAutoStart) }
    }

    /// 网易云用哪条通道。
    ///
    /// 默认 `plain`（明文接口）—— 实测加密的 weapi 通道**已经被网易掐掉**：
    /// 无论怎么签名、带不带 cookie，搜索都恒定返回 `{"code":50000005}`，
    /// 而同一台机器上走明文 `/api/search/get` 立刻能搜到 335 条结果。
    ///
    /// 留这个开关不是给用户玩的，是给自己留后路：万一哪天明文也被掐，
    /// 在诊断页切回 `weapi` 就能当场验证，不用重新出包。
    @Published var neteaseChannel: String {
        didSet { UserDefaults.standard.set(neteaseChannel, forKey: Key.neteaseChannel) }
    }

    // MARK: - QQ 桥接（OneBot 兼容）
    //
    // QQ 没有给第三方的 IM 接口，**App 也没法在手机上自己登 QQ**（详见 QQBridge
    // 的注释）。所以通行做法是**在外面跑一个 OneBot 实现**（NapCat / LLOneBot /
    // go-cqhttp），由它登录，对外开一个 HTTP 端口，手机连过去。
    //
    // ⚠️「外面」不等于「电脑」：放服务器上更好 —— 手机在任何网络下都能用，
    // 也不用一直开着电脑。用户明确说过不想依赖电脑。
    // 不管跑在哪，账号密码都不经过这个 App。

    /// 整块功能的总开关。关着就等于没这回事。
    @Published var qqBridgeEnabled: Bool {
        didSet { UserDefaults.standard.set(qqBridgeEnabled, forKey: Key.qqBridgeEnabled) }
    }

    /// 那个 OneBot 服务的地址，形如 `https://qq.example.com` 或 `http://192.168.1.5:3000`。
    /// **留空就整块不生效**，不会报错 —— 没配的东西就该安静地不存在。
    ///
    /// 填公网地址最好（手机在哪都能用、不用开着电脑）；填局域网地址就只有
    /// 同一个 WiFi 下能用。
    @Published var qqBridgeURL: String {
        didSet { UserDefaults.standard.set(qqBridgeURL, forKey: Key.qqBridgeURL) }
    }

    /// OneBot 的 Access Token。**只进钥匙串**，和 API Key 一个待遇。
    @Published var qqBridgeToken: String {
        didSet { Keychain.set(qqBridgeToken, for: Key.qqBridgeTokenKeychain) }
    }

    /// 允不允许她**以用户本人的身份发 QQ 消息**。
    ///
    /// 出厂开着（不然这个功能没意义），但它是个开关：
    /// 不想让人替自己说话的时候关掉，读消息不受影响。
    @Published var qqBridgeCanSend: Bool {
        didSet { UserDefaults.standard.set(qqBridgeCanSend, forKey: Key.qqBridgeCanSend) }
    }

    // MARK: - QQ 官方机器人
    //
    // ⭐ **这条是唯一能「在手机上、不用电脑、不用服务器」跑 QQ 的路**：
    // 官方机器人由平台替你登录，我们只是一个 HTTPS + WebSocket 客户端。
    // 详见 QQBotClient / QQBotService 的注释。走这条就不需要上面那个 OneBot 桥接了。

    /// 总开关。
    @Published var qqBotEnabled: Bool {
        didSet { UserDefaults.standard.set(qqBotEnabled, forKey: Key.qqBotEnabled) }
    }

    /// QQ 开放平台给的 AppID。**它不是密钥**，可以明文放这儿。
    @Published var qqBotAppID: String {
        didSet { UserDefaults.standard.set(qqBotAppID, forKey: Key.qqBotAppID) }
    }

    /// AppSecret。**只进钥匙串**。
    /// ⚠️ 平台那边不支持二次查看 —— 再点一次会强制重置，所以填进来之后自己留好一份。
    @Published var qqBotSecret: String {
        didSet { Keychain.set(qqBotSecret, for: Key.qqBotSecretKeychain) }
    }

    /// 用沙箱环境（只有加进去的测试成员能用）。先做通再关掉。
    @Published var qqBotSandbox: Bool {
        didSet { UserDefaults.standard.set(qqBotSandbox, forKey: Key.qqBotSandbox) }
    }

    /// 后台静音保活。**出厂开** —— 不开的话他在 QQ 里聊、App 一进后台被挂起，她就不回了。
    /// 但它费电，所以给开关（用户的原则：能自定义的都自定义）。
    @Published var qqBotKeepAlive: Bool {
        didSet { UserDefaults.standard.set(qqBotKeepAlive, forKey: Key.qqBotKeepAlive) }
    }

    // MARK: - QQ 机器人：发注册码
    //
    // 用户在 QQ 里发「注册」就能领一张注册码，**一个 QQ 一张**。
    //
    // ⚠️ 为什么要"群里拿口令、私聊换码"两步（见 QQCodeGate 里的详解）：
    // 官方**没有**可用的「查群成员」接口（群成员列表还在内邀），而且
    // 私聊用的是 user_openid、群聊用的是 member_openid，**是两个不同的值** ——
    // 所以在私聊里没法反查对方是不是群成员。
    // 于是把"证明他在群里"搬回群里做：他能在群里 @ 到机器人，这件事本身就是证据。

    /// 总开关。**出厂关** —— 这是一条"往外发东西"的功能，
    /// 钥匙没填就打开，只会让他每次发「注册」都收到一句报错。
    @Published var qqBotCodeEnabled: Bool {
        didSet { UserDefaults.standard.set(qqBotCodeEnabled, forKey: Key.qqBotCodeEnabled) }
    }

    /// 触发词。默认「注册」，用户想换成什么都行。
    @Published var qqBotCodeKeyword: String {
        didSet { UserDefaults.standard.set(qqBotCodeKeyword, forKey: Key.qqBotCodeKeyword) }
    }

    /// 服务器发码钥匙。**只进钥匙串**。
    ///
    /// 它不在公开仓库里，也不走 GitHub Secrets —— 用户从自己的管理后台
    /// （account.lingyan.cyou/admin）复制过来填一次。少一个要他配置的地方。
    @Published var qqBotCodeKey: String {
        didSet { Keychain.set(qqBotCodeKey, for: Key.qqBotCodeKeyKeychain) }
    }

    /// 哪些群能领注册码。**空 = 不限**（机器人所在的群都行）。
    /// 存 JSON 数组 —— UserDefaults 不认 [String] 这种自定义类型。
    @Published var qqBotCodeGroups: [String] {
        didSet {
            let data = try? JSONEncoder().encode(qqBotCodeGroups)
            UserDefaults.standard.set(data, forKey: Key.qqBotCodeGroups)
        }
    }

    // MARK: - 账号（给「以后那个服务器」留的）
    //
    // 用户说「到时候会拿新的服务器跟你对接」。所以现在**只做接口层**：
    // 地址他自己填、留空就是未连接，本地功能一样都不少。

    /// 服务器地址，形如 `https://api.example.com`。**留空 = 未连接**。
    @Published var accountServerURL: String {
        didSet { UserDefaults.standard.set(accountServerURL, forKey: Key.accountServerURL) }
    }

    /// 登录后的 token。**只进钥匙串**，和 API Key 一个待遇。
    @Published var accountToken: String {
        didSet { Keychain.set(accountToken, for: Key.accountTokenKeychain) }
    }

    /// token 的到期时刻（Unix 秒）。0 表示没记录。
    @Published var accountExpiresAt: Double {
        didSet { UserDefaults.standard.set(accountExpiresAt, forKey: Key.accountExpiresAt) }
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

    // MARK: - 百度网盘

    /// 百度网盘开放平台的应用凭据。
    ///
    /// **SecretKey 也进钥匙串** —— 它能换 token，和 Cookie、API Key 一个待遇。
    /// 为什么要用户自己申请：App 拿不到"用户的网盘"，
    /// 必须由开发者应用出面走一次 OAuth 授权，这是百度的规矩。
    @Published var baiduPanAppKey: String {
        didSet { Keychain.set(baiduPanAppKey, for: Key.baiduPanAppKey) }
    }

    @Published var baiduPanSecretKey: String {
        didSet { Keychain.set(baiduPanSecretKey, for: Key.baiduPanSecretKey) }
    }

    /// 授权后拿到的通行证（约 30 天）和用来续期的 refresh_token。
    @Published var baiduPanToken: String {
        didSet { Keychain.set(baiduPanToken, for: Key.baiduPanToken) }
    }

    @Published var baiduPanRefreshToken: String {
        didSet { Keychain.set(baiduPanRefreshToken, for: Key.baiduPanRefreshToken) }
    }

    /// 授权完成后百度往哪跳。
    ///
    /// 默认 `oob`：百度会把**授权码直接显示在页面上**，用户复制回来就能用。
    /// 开发者后台如果登记的是内网地址（`http://192.168.x.x/...`），
    /// 手机上多半打不开那个页面 —— 但地址栏里会带 `?code=xxx`，
    /// 复制出来一样能用。所以两种情况这个字段都不用改，
    /// 填成跟后台一致的那个值就行。
    @Published var baiduPanRedirect: String {
        didSet { UserDefaults.standard.set(baiduPanRedirect, forKey: Key.baiduPanRedirect) }
    }

    /// 通行证到期时刻（Unix 秒）。0 表示还没授权过。
    @Published var baiduPanExpiresAt: Double {
        didSet { UserDefaults.standard.set(baiduPanExpiresAt, forKey: Key.baiduPanExpiresAt) }
    }

    /// 最近一次授权失败的原因原文，直接显示给用户。
    @Published var baiduPanLastError: String {
        didSet { UserDefaults.standard.set(baiduPanLastError, forKey: Key.baiduPanLastError) }
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
        densityIndex = defaults.object(forKey: Key.densityIndex) as? Int ?? 1
        dynamicAccent = defaults.object(forKey: Key.dynamicAccent) as? Bool ?? false
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
        // ——— 朋友圈个性化（默认值刻意「不改变现状」：风格留空 = 自由发挥；
        //      四个时段都填 50 = 相对比例全是 1，等价于原来的平均间隔）———
        momentStylePrompt = defaults.string(forKey: Key.momentStylePrompt) ?? ""
        momentImageMode = defaults.string(forKey: Key.momentImageMode) ?? "none"
        momentMorningWeight = defaults.object(forKey: Key.momentMorningWeight) as? Int ?? 50
        momentNoonWeight = defaults.object(forKey: Key.momentNoonWeight) as? Int ?? 50
        momentEveningWeight = defaults.object(forKey: Key.momentEveningWeight) as? Int ?? 50
        momentNightWeight = defaults.object(forKey: Key.momentNightWeight) as? Int ?? 50
        momentFontScale = defaults.object(forKey: Key.momentFontScale) as? Double ?? 1.0
        momentDensityIndex = defaults.object(forKey: Key.momentDensityIndex) as? Int ?? 1
        momentTimeStyle = defaults.string(forKey: Key.momentTimeStyle) ?? "relative"
        momentCorner = defaults.object(forKey: Key.momentCorner) as? Double ?? 16
        douyinConfirmRisky = defaults.object(forKey: Key.douyinConfirmRisky) as? Bool ?? true
        companionEnabled = defaults.object(forKey: Key.companionEnabled) as? Bool ?? false
        companionInterval = defaults.object(forKey: Key.companionInterval) as? Double ?? 20
        shortcutName = defaults.string(forKey: Key.shortcutName) ?? ""
        defaultTab = defaults.string(forKey: Key.defaultTab) ?? "contacts"
        lockShortcutName = defaults.string(forKey: Key.lockShortcutName) ?? ""
        screenTimeShortcutName = defaults.string(forKey: Key.screenTimeShortcutName) ?? ""
        listenTogetherMode = defaults.string(forKey: Key.listenTogetherMode) ?? ListenTogetherMode.sync.rawValue
        // ⚠️ 必须用 object(forKey:) 判「有没有设过」。
        // 直接 bool(forKey:) 在没设过时返回 false —— 而出厂值是 **true**（开），
        // 用错就把默认值反过来了。
        listenTogetherAutoStart = defaults.object(forKey: Key.listenTogetherAutoStart) as? Bool ?? true
        neteaseCookie = Keychain.get(Key.neteaseCookieKeychain) ?? ""
        douyinCookie = Keychain.get(Key.douyinCookieKeychain) ?? ""
        qqBridgeToken = Keychain.get(Key.qqBridgeTokenKeychain) ?? ""
        qqBridgeEnabled = defaults.object(forKey: Key.qqBridgeEnabled) as? Bool ?? false
        qqBridgeURL = defaults.string(forKey: Key.qqBridgeURL) ?? ""
        // 出厂允许她替你发 —— 这是这个功能的意义所在；不想让人替自己说话的可以关掉
        qqBridgeCanSend = defaults.object(forKey: Key.qqBridgeCanSend) as? Bool ?? true
        // QQ 官方机器人
        qqBotEnabled = defaults.object(forKey: Key.qqBotEnabled) as? Bool ?? false
        qqBotAppID = defaults.string(forKey: Key.qqBotAppID) ?? ""
        qqBotSecret = Keychain.get(Key.qqBotSecretKeychain) ?? ""
        qqBotSandbox = defaults.object(forKey: Key.qqBotSandbox) as? Bool ?? true
        // 出厂开：不开的话他在 QQ 里聊、App 进后台被挂起，她就不回了
        qqBotKeepAlive = defaults.object(forKey: Key.qqBotKeepAlive) as? Bool ?? true
        qqBotCodeEnabled = defaults.object(forKey: Key.qqBotCodeEnabled) as? Bool ?? false
        qqBotCodeKeyword = defaults.string(forKey: Key.qqBotCodeKeyword) ?? "注册"
        qqBotCodeKey = Keychain.get(Key.qqBotCodeKeyKeychain) ?? ""
        // JSON 存 [String]：UserDefaults 只认 plist 里那几种类型，数组要自己编码
        if let data = defaults.data(forKey: Key.qqBotCodeGroups),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            qqBotCodeGroups = list
        } else {
            qqBotCodeGroups = []
        }
        accountServerURL = defaults.string(forKey: Key.accountServerURL) ?? ""
        accountToken = Keychain.get(Key.accountTokenKeychain) ?? ""
        accountExpiresAt = defaults.double(forKey: Key.accountExpiresAt)
        neteaseChannel = defaults.string(forKey: Key.neteaseChannel) ?? "plain"
        // 百度网盘凭据：**用户自己填的优先，没填就用编译时注入的那份**
        // （见 BuiltInSecrets 的说明：仓库里那份是空值，真值只在 CI 注入）。
        // 这样两种人都能用 —— 你自己填自己的，朋友拿到包直接开箱。
        let storedAppKey = Keychain.get(Key.baiduPanAppKey) ?? ""
        baiduPanAppKey = storedAppKey.isEmpty ? BuiltInSecrets.baiduPanAppKey : storedAppKey
        let storedSecret = Keychain.get(Key.baiduPanSecretKey) ?? ""
        baiduPanSecretKey = storedSecret.isEmpty ? BuiltInSecrets.baiduPanSecretKey : storedSecret
        baiduPanToken = Keychain.get(Key.baiduPanToken) ?? ""
        baiduPanRefreshToken = Keychain.get(Key.baiduPanRefreshToken) ?? ""
        baiduPanRedirect = defaults.string(forKey: Key.baiduPanRedirect) ?? "oob"
        baiduPanExpiresAt = defaults.double(forKey: Key.baiduPanExpiresAt)
        baiduPanLastError = defaults.string(forKey: Key.baiduPanLastError) ?? ""
        customBackgroundData = try? Data(contentsOf: Self.backgroundFileURL)
    }

    // MARK: - 派生

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accentColor: Color {
        // 用户勾了「主题色跟着 TA 的头像走」而且真取到了颜色，就用它；
        // 取不到（没设头像 / 取色失败）就老老实实回到他挑的那一个 —— 不能变透明。
        if dynamicAccent, let avatarTint { return avatarTint }
        let index = min(max(accentIndex, 0), Self.accentPalette.count - 1)
        return Self.accentPalette[index]
    }

    /// 界面密度：紧凑 / 标准 / 宽松。
    /// 只作用在**间距和留白**上 —— 字号另有开关，这两件事别混在一起。
    var densityScale: Double {
        switch min(max(densityIndex, 0), 2) {
        case 0: return 0.82
        case 2: return 1.22
        default: return 1.0
        }
    }

    static let densityNames = ["紧凑", "标准", "宽松"]

    /// 从一张图里取主色。
    ///
    /// 做法很省：把整张图**平均成一个像素**（`CIAreaAverage`），再把这个
    /// 平均色往「能当主题色用」的方向调一下 —— 平均色往往发灰，
    /// 直接拿来做主题色会显得脏。
    ///
    /// 只在头像变化时调一次，不在渲染路径上。
    static func dominantColor(of image: UIImage) -> Color? {
        #if canImport(UIKit)
        guard let ciImage = CIImage(image: image), !ciImage.extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        let base = UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )

        // 提饱和度、把亮度夹到「能用」的区间 —— 太暗会看不清，太亮会发白
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return Color(
            hue: Double(hue),
            saturation: Double(min(0.85, max(0.45, saturation))),
            brightness: Double(min(0.95, max(0.55, brightness)))
        )
        #else
        return nil
        #endif
    }

    // MARK: - 从头像取主题色

    /// 从头像图里取一个主色当主题色。
    ///
    /// ⚠️ **不能在 `accentColor` 里现算** —— 那个属性被几十处界面读，
    /// 每次都跑一遍 CoreImage 会把界面拖死。所以只在头像变化时算一次，
    /// 结果放在 `avatarTint` 里。
    func refreshAvatarTint(from image: UIImage?) {
        guard dynamicAccent else { return }
        guard let image else {
            avatarTint = nil
            return
        }
        avatarTint = Self.dominantColor(of: image)
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
