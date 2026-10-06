import Foundation

// =============================================================================
//  她的小手机 —— App 目录（数据层）
// =============================================================================
//
//  这个文件只干一件事：把「她手机上每个 App 点开之后长什么样」集中定义在一处，
//  给人肉的默认值、语义、以及两套类型。**不画任何界面** —— 界面在下一轮由
//  `HerPhoneView.swift` 按下面这套签名来写。
//
//  ────────────────────────────────────────────────────────────────────────────
//  ★ 最终公开签名（下一轮同事照它写界面，别改）★
//  ────────────────────────────────────────────────────────────────────────────
//
//  enum HerAppSurface: Codable, Hashable
//      case herChat(platform: HerChatPlatform)   // 她的聊天列表（自绘）
//      case herWallet                            // 她的钱包/账单（WalletStore）
//      case herNetdisk                           // 真·百度网盘（BaiduPanClient）
//      case herPhotos                            // 她的相册
//      case herMusic                             // 她的音乐（接现有网易云）
//      case herMap                               // 她的位置/地图
//      case herMoments                           // 她的朋友圈
//      case browser(URL?)                        // 真浏览器打开（nil = 起始页）
//      case externalApp(String)                  // URL scheme 唤起真 App（如 "weixin://"）
//      case generic                              // 兜底：只显示一句"她打开了 X"
//
//  enum HerChatPlatform: String, Codable, Hashable
//      case wechat
//      case qq
//
//  struct HerAppCatalogEntry: Identifiable, Hashable
//      let id: String          // 稳定 slug（"wechat" / "qq" …），**不改现有 slug**
//      let name: String
//      let symbol: String      // SF Symbol 名
//      let accent: String?     // 语义色名（"green" / "blue" …）
//      let surface: HerAppSurface
//      let isBuiltin: Bool
//
//  enum HerAppCatalog
//      static let entries: [HerAppCatalogEntry]        // 全部条目（15 个）
//      static let defaultIDs: [String]                 // 默认"装"到手机上的顺序
//      static func entry(forID id: String) -> HerAppCatalogEntry?
//      static func entry(forName name: String) -> HerAppCatalogEntry?
//      static func surface(forID id: String) -> HerAppSurface   // 查不到 → .generic
//      static func defaultApps() -> [HerApp]           // 默认那部手机装好的 App
//
//  （`HerApp` 上新增的字段见 `HerPhoneStore.swift` 顶部注释。）
//
//  ⚠️ 持久化安全：`HerAppSurface` 会跟着 `HerApp` 一起进存档，所以它**手写了**
//     `init(from:)` / `encode(to:)`，用 `kind`(String) + `value`(String?) 两个
//     扁平字段，**不**用自动合成的「枚举关联值」不透明格式 —— 那样以后加一个
//     case 就会让老存档解析失败。未知 `kind` 一律退化成 `.generic`，绝不抛错。
// =============================================================================

/// 点开一个 App 之后，她的手机里呈现什么。
///
/// 这是「面」的枚举 —— 界面拿到它之后决定推哪一页。它是 `Codable` 的
/// （跟着 `HerApp` 进存档），但**必须**能安全地解码未知/残缺数据，
/// 所以下面手写了 `init(from:)` / `encode(to:)`。
enum HerAppSurface: Codable, Hashable {

    /// 她的聊天列表。`platform` 决定接微信还是 QQ 那套数据。
    case herChat(platform: HerChatPlatform)
    /// 她的钱包 / 账单（数据来自 `WalletStore`）。
    case herWallet
    /// 真·百度网盘（数据来自 `BaiduPanClient`）。
    case herNetdisk
    /// 她的相册。
    case herPhotos
    /// 她的音乐（接现有音乐 / 网易云那套）。
    case herMusic
    /// 她的位置 / 地图。
    case herMap
    /// 她的朋友圈。
    case herMoments
    /// 真浏览器打开（真 WebKit 内核，组件是同一天另建的 `InAppBrowser`）。
    /// `nil` = 浏览器起始页。
    case browser(URL?)
    /// 用 URL scheme 唤起系统里**真的** App（如 `"weixin://"`）。
    case externalApp(String)
    /// 兜底：没有二级页，只显示一句"她打开了 X"。
    case generic

    /// 存档里只认这两个 key：`kind` 标记是哪种面，`value` 带一个可选的参数串。
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    // MARK: - 持久化（手写，容错）

    /// 从存档解出一个「面」。
    ///
    /// 判据只看 `kind` 字符串；`kind` 缺失 / 未知 / 类型不对 —— 一律退化成 `.generic`，
    /// **绝不抛错**。`value` 用来携带参数（浏览器地址、外部 App 的 scheme）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // `String??` → 压成 `String?`：key 不在、值为 null、类型不对都得到 nil。
        let kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        let value = (try? container.decodeIfPresent(String.self, forKey: .value)) ?? nil

        switch kind ?? "" {
        case "herChat":
            // 平台串认不出来（老数据/脏数据）就当微信 —— 聊天列表是安全默认。
            let raw = value ?? ""
            self = .herChat(platform: HerChatPlatform(rawValue: raw) ?? .wechat)
        case "herWallet":
            self = .herWallet
        case "herNetdisk":
            self = .herNetdisk
        case "herPhotos":
            self = .herPhotos
        case "herMusic":
            self = .herMusic
        case "herMap":
            self = .herMap
        case "herMoments":
            self = .herMoments
        case "browser":
            // 地址非法 / 缺失 ⇒ `.browser(nil)`（打开起始页），不是错误。
            self = .browser(value.flatMap { URL(string: $0) })
        case "externalApp":
            self = .externalApp(value ?? "")
        default:
            // 含 "generic" 以及**任何将来才加、当前不认识的 kind**。
            self = .generic
        }
    }

    /// 写进存档。和上面的 `init(from:)` 一直是同一套 `kind` / `value` 口径。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .herChat(let platform):
            try container.encode("herChat", forKey: .kind)
            try container.encode(platform.rawValue, forKey: .value)
        case .herWallet:
            try container.encode("herWallet", forKey: .kind)
        case .herNetdisk:
            try container.encode("herNetdisk", forKey: .kind)
        case .herPhotos:
            try container.encode("herPhotos", forKey: .kind)
        case .herMusic:
            try container.encode("herMusic", forKey: .kind)
        case .herMap:
            try container.encode("herMap", forKey: .kind)
        case .herMoments:
            try container.encode("herMoments", forKey: .kind)
        case .browser(let url):
            try container.encode("browser", forKey: .kind)
            // 起始页（nil）就不写 value —— 解码时缺 value 一样得到 `.browser(nil)`。
            if let url {
                try container.encode(url.absoluteString, forKey: .value)
            }
        case .externalApp(let scheme):
            try container.encode("externalApp", forKey: .kind)
            try container.encode(scheme, forKey: .value)
        case .generic:
            try container.encode("generic", forKey: .kind)
        }
    }
}

/// 她的聊天列表要接哪套聊天数据。`rawValue` 同时也是存档里的 `value`。
enum HerChatPlatform: String, Codable, Hashable {
    case wechat
    case qq
}

/// 目录里的一条：一个 App 的"长相 + 点开之后走哪种面"。
///
/// ⚠️ `id` 是**稳定 slug**（`"wechat"` / `"qq"` …）。这些 slug 已经写进过用户
///    存档，**绝对不能改** —— 改了旧数据就对不上、`surface` 补不上。
struct HerAppCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    /// SF Symbol 名。**必须是系统里真有的符号**，否则图标渲染成空白。
    let symbol: String
    /// 语义色名（`"green"` / `"blue"` …）；`nil` = 让界面按名字算色。
    let accent: String?
    /// 点开之后走哪种面。
    let surface: HerAppSurface
    /// 内置 App（出厂就装好的）能不能卸载。
    let isBuiltin: Bool
}

/// 集中式的 App 目录。
///
/// 唯一事实来源：**新增/调整一个 App 只改这里**。
/// `HerPhoneStore.defaultApps` 和 store 的 `surface` 回填都从这里取。
enum HerAppCatalog {

    // MARK: - 全部条目

    /// 全部 App 条目。顺序 = 出厂手机上的排列顺序。
    ///
    /// 分组说明：
    ///   · 微信 / QQ …… 走她的聊天列表（`.herChat`）；
    ///   · 支付宝 …… 她的钱包（`.herWallet`）；
    ///   · 百度网盘 …… 真网盘（`.herNetdisk`）；
    ///   · 相机 …… 她的相册（`.herPhotos`）；
    ///   · 网易云音乐 …… 她的音乐（`.herMusic`）；
    ///   · 高德地图 …… 她的位置（`.herMap`）；
    ///   · 淘宝 / 拼多多 / 小红书 / 美团 / 推特 …… 真浏览器开手机网页（`.browser`）；
    ///   · 浏览器 …… 真浏览器起始页（`.browser(nil)`）；
    ///   · 王者荣耀 / 抖音 …… 没有能用的网页版，兜底（`.generic`）。
    static let entries: [HerAppCatalogEntry] = [
        HerAppCatalogEntry(
            id: "wechat", name: "微信", symbol: "message.fill",
            accent: "green",
            surface: .herChat(platform: .wechat),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "qq", name: "QQ", symbol: "bubble.left.and.bubble.right.fill",
            accent: "blue",
            surface: .herChat(platform: .qq),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "taobao", name: "淘宝", symbol: "bag.fill",
            accent: "orange",
            surface: .browser(URL(string: "https://m.taobao.com/")),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "pinduoduo", name: "拼多多", symbol: "cart.fill",
            accent: "red",
            surface: .browser(URL(string: "https://mobile.yangkeduo.com/")),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "douyin", name: "抖音", symbol: "music.note",
            accent: "gray",
            // 该项目里抖音相关功能已删，没有网页版 —— 兜底，不引任何 Douyin 文件。
            surface: .generic,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "xiaohongshu", name: "小红书", symbol: "book.fill",
            accent: "red",
            surface: .browser(URL(string: "https://www.xiaohongshu.com/")),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "meituan", name: "美团", symbol: "fork.knife",
            accent: "yellow",
            surface: .browser(URL(string: "https://m.meituan.com/")),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "netease", name: "网易云音乐", symbol: "headphones",
            accent: "red",
            surface: .herMusic,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "wangzhe", name: "王者荣耀", symbol: "gamecontroller.fill",
            accent: "indigo",
            // 端游/手游都没有网页版 —— 兜底。
            surface: .generic,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "alipay", name: "支付宝", symbol: "creditcard.fill",
            accent: "blue",
            surface: .herWallet,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "gaode", name: "高德地图", symbol: "map.fill",
            accent: "teal",
            surface: .herMap,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "camera", name: "相机", symbol: "camera.fill",
            accent: "gray",
            surface: .herPhotos,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "twitter", name: "推特", symbol: "at",
            accent: "blue",
            surface: .browser(URL(string: "https://x.com/")),
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "baidupan", name: "百度网盘", symbol: "cloud.fill",
            accent: "blue",
            surface: .herNetdisk,
            isBuiltin: true
        ),
        HerAppCatalogEntry(
            id: "browser", name: "浏览器", symbol: "safari",
            accent: "blue",
            // nil = 浏览器起始页（不是错误）。
            surface: .browser(nil),
            isBuiltin: true
        )
    ]

    /// 出厂默认「装」在 ta 手机上的 App，按屏上的先后顺序。
    ///
    /// 老 12 个（沿用现有 slug 与顺序）+ 老板点名要补的 3 个（推特 / 百度网盘 / 浏览器）。
    static let defaultIDs: [String] = [
        "wechat", "qq", "taobao", "pinduoduo", "douyin", "xiaohongshu",
        "meituan", "netease", "wangzhe", "alipay", "gaode", "camera",
        "twitter", "baidupan", "browser"
    ]

    // MARK: - 查询

    /// 按稳定 slug 找条目。查不到返回 `nil`。
    static func entry(forID id: String) -> HerAppCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// 按显示名找条目（用户手动"安装"一个已知 App 时用）。查不到返回 `nil`。
    static func entry(forName name: String) -> HerAppCatalogEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.first { $0.name == trimmed }
    }

    /// 按 id 查这个 App 该走哪种面。**查不到一律 `.generic`** —— 绝不返回 nil，
    /// 保证调用方（store 的回填、界面）永远拿到一个能用的值。
    static func surface(forID id: String) -> HerAppSurface {
        entry(forID: id)?.surface ?? .generic
    }

    // MARK: - 默认那部手机

    /// 出厂手机装好的 App（`defaultIDs` 依次展开成 `HerApp`）。
    ///
    /// `order` 用 1 起的序号，把出厂顺序钉在数据里，方便界面按它排。
    static func defaultApps() -> [HerApp] {
        var result: [HerApp] = []
        for (offset, id) in defaultIDs.enumerated() {
            guard let entry = entry(forID: id) else { continue }
            result.append(HerApp(
                id: entry.id,
                name: entry.name,
                symbol: entry.symbol,
                surface: entry.surface,
                accent: entry.accent,
                isBuiltin: entry.isBuiltin,
                order: offset + 1
            ))
        }
        return result
    }
}
