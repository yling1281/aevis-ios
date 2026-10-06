import SwiftUI

/// 播放器皮肤（预设）。
///
/// ## 为什么要这个东西
/// 用户要「播放器的 UI 是可以改的，多设几个预设」。可改动前**根本没有「皮肤」这件事**：
/// 播放页的配色是硬编码的 —— 底色写死纯黑、字写死白色，唯一会变的是跟着全局主题色
/// 走的强调色（`AppSettings.shared.accentColor`）。也就是说，除了改全局主题色，
/// 用户没法让播放器换个样子。
///
/// 这个文件把它抽出来：一套皮肤就是一个 `PlayerTheme`，播放页只认
/// `PlayerTheme.current`，不再到处直接读全局取色。
///
/// ## 取色约定
/// 颜色一律写成 `Color(red:green:blue:)` 的 0–1 小数，跟 `AppSettings` 里的取色板
/// 保持同一种写法，免得以后有人两种写法混着用。
///
/// ## 默认那套：跟改动前**长得一样**
/// 默认的 `深夜` 就是「强制深色 + 底色近黑 + 字全白 + 强调色跟随全局」——
/// 也就是改动前播放页的观感。用户升上来不该觉得「界面怎么被动了」，
/// 所以它的强调色用 `accentFollowsGlobal = true`，实时向 `AppSettings` 取。
///
/// ## 存取不走 `AppSettings`
/// 皮肤是自己一个键（`UserDefaults`），**不塞进** `AppSettings` ——
/// 那是主题色/字体那些全局设置的地方，播放器皮肤只管播放器，
/// 两件事别搅在一起（也避免动那个到处被读的大对象）。
struct PlayerTheme: Identifiable, Equatable {

    // MARK: - 身份

    /// 稳定标识。存进 `UserDefaults` 的是它，不是名字 ——
    /// 名字以后可以改，标识不能改，否则用户存的皮肤就「丢了」。
    let id: String

    /// 给用户看的名字，比如「深夜」「极简白」。
    let name: String

    /// 一句话说明这套皮肤什么感觉，切换面板里显示。
    let tagline: String

    // MARK: - 颜色

    /// 页面底色。模糊封面下面铺的那一层，也是各处「深/浅」的基准。
    let background: Color

    /// 主色。唱片本体、中间的播放按钮、上/下一首那些主控件都用它。
    let primary: Color

    /// 强调色。切换开关、「打字聊」那颗胶囊之类「点睛」的地方用它。
    /// ⚠️ 默认那套不写死，见 `accent`。
    let accentFollowsGlobal: Bool

    /// 已唱的那句歌词的颜色（当前那句，最醒目）。
    let lyricDone: Color

    /// 还没唱的那句歌词的颜色（下一句，压暗一点）。
    let lyricWaiting: Color

    /// 页面上的正文/控件文字颜色。深色皮肤是白、浅色皮肤是近黑。
    let onBackground: Color

    /// 是否强制深色状态栏与外框。深色皮肤 `true`，浅色皮肤 `false`。
    let forcesDark: Bool

    /// 各套皮肤自己定的强调色。`accentFollowsGlobal` 为真时忽略它。
    private let storedAccent: Color

    // MARK: - 派生

    /// 用户的皮肤该取哪个强调色。
    ///
    /// 默认那套（深夜）**实时**向 `AppSettings.shared.accentColor` 取 ——
    /// 这样用户改全局主题色、或者开着「跟随头像取色」时，播放器还跟以前一样跟着变，
    /// 不会因为这次改动而「定格」成某一种颜色。其余几套各有各的强调色。
    var accent: Color {
        accentFollowsGlobal ? AppSettings.shared.accentColor : storedAccent
    }

    /// 这套皮肤对应的配色方案，直接喂给 `preferredColorScheme`。
    var scheme: ColorScheme {
        forcesDark ? .dark : .light
    }

    // MARK: - 初始化

    init(
        id: String,
        name: String,
        tagline: String,
        background: Color,
        primary: Color,
        accent: Color,
        lyricDone: Color,
        lyricWaiting: Color,
        onBackground: Color,
        forcesDark: Bool,
        accentFollowsGlobal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.background = background
        self.primary = primary
        self.storedAccent = accent
        self.lyricDone = lyricDone
        self.lyricWaiting = lyricWaiting
        self.onBackground = onBackground
        self.forcesDark = forcesDark
        self.accentFollowsGlobal = accentFollowsGlobal
    }

    /// 只按标识比 —— 强调色可能随时间/全局设置变（默认那套），
    /// 用 id 判断「选中的是哪一套」才稳定。
    static func == (lhs: PlayerTheme, rhs: PlayerTheme) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 预置皮肤

extension PlayerTheme {

    /// 存放「用户选了哪套皮肤」的 `UserDefaults` 键。
    ///
    /// 自己一个键，不走 `AppSettings` —— 播放器皮肤跟全局主题色是两码事。
    static let storageKey = "aevis.playerTheme"

    /// 出厂默认皮肤。用户没选过时用它。
    static var defaultTheme: PlayerTheme { all[0] }

    /// 五套预置。第一个是默认。
    ///
    /// 挑配色的两条硬要求（这是要卖钱的产品，不能难看）：
    /// ① **对比度够** —— 歌词、歌名压得住底，别糊成一团；
    /// ② **深色不要纯黑压死** —— 纯黑配纯白太硬，稍微提一点蓝/棕，看着透气。
    static let all: [PlayerTheme] = [
        midnight, minimal, vinyl, neon, sakura
    ]

    /// 用户当前选的皮肤。存过就按存的来，没存过/存坏了就回到默认。
    static var current: PlayerTheme {
        let id = UserDefaults.standard.string(forKey: storageKey) ?? defaultTheme.id
        return all.first { $0.id == id } ?? defaultTheme
    }

    /// 选中一套皮肤并写盘。播放页点完立即生效依赖它。
    static func set(_ theme: PlayerTheme) {
        UserDefaults.standard.set(theme.id, forKey: storageKey)
    }

    // MARK: - 五套

    /// 1. 深夜 —— **默认**，就是改动前的观感：近黑底 + 纯白字 + 强调色跟随全局。
    static let midnight = PlayerTheme(
        id: "midnight",
        name: "深夜",
        tagline: "近黑的底衬着封面，白字清清爽爽 —— 默认就是这个。",
        background: rgb(10, 10, 12),
        primary: rgb(255, 255, 255),
        // 这个值不直接用，见 accentFollowsGlobal —— 写一个只为构造器完整。
        accent: rgb(120, 100, 255),
        lyricDone: rgb(255, 255, 255),
        lyricWaiting: rgb(255, 255, 255).opacity(0.50),
        onBackground: rgb(255, 255, 255),
        forcesDark: true,
        accentFollowsGlobal: true
    )

    /// 2. 极简白 —— 浅色，暖白底 + 近黑字 + 一点克制的蓝。
    static let minimal = PlayerTheme(
        id: "minimal",
        name: "极简白",
        tagline: "暖白底配近黑的字，干净、克制，白天看最舒服。",
        background: rgb(247, 247, 245),
        primary: rgb(28, 28, 30),
        accent: rgb(74, 108, 247),
        lyricDone: rgb(28, 28, 30),
        lyricWaiting: rgb(28, 28, 30).opacity(0.42),
        onBackground: rgb(28, 28, 30),
        forcesDark: false
    )

    /// 3. 复古唱片 —— 深咖啡底 + 奶油白字 + 黄铜色，像老唱机和黑胶。
    static let vinyl = PlayerTheme(
        id: "vinyl",
        name: "复古唱片",
        tagline: "深咖啡衬奶油白，配一点黄铜色，像翻出一张老黑胶。",
        background: rgb(26, 18, 11),
        primary: rgb(232, 192, 138),
        accent: rgb(201, 139, 60),
        lyricDone: rgb(245, 230, 207),
        lyricWaiting: rgb(245, 230, 207).opacity(0.45),
        onBackground: rgb(240, 223, 198),
        forcesDark: true
    )

    /// 4. 霓虹 —— 深紫底 + 青与玫红，夜里最跳的一档。
    static let neon = PlayerTheme(
        id: "neon",
        name: "霓虹",
        tagline: "深紫底上跑青与玫红，夜里最亮眼的那一档。",
        background: rgb(11, 4, 32),
        primary: rgb(0, 240, 255),
        accent: rgb(255, 61, 203),
        lyricDone: rgb(242, 240, 255),
        lyricWaiting: rgb(201, 168, 255).opacity(0.60),
        onBackground: rgb(234, 246, 255),
        forcesDark: true
    )

    /// 5. 樱花 —— 浅樱花粉底 + 玫粉主色，软一点。
    static let sakura = PlayerTheme(
        id: "sakura",
        name: "樱花",
        tagline: "淡淡的粉底配玫粉，软软的那种，适合慢歌。",
        background: rgb(255, 240, 244),
        primary: rgb(232, 106, 146),
        accent: rgb(242, 145, 180),
        lyricDone: rgb(74, 43, 54),
        lyricWaiting: rgb(74, 43, 54).opacity(0.45),
        onBackground: rgb(90, 51, 64),
        forcesDark: false
    )
}

// MARK: - 取色小工具

/// 按 0–255 写颜色，省得满屏 `0.42`: `rgb(255, 255, 255)` 一眼就知道是纯白。
private func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
    Color(red: r / 255, green: g / 255, blue: b / 255)
}
