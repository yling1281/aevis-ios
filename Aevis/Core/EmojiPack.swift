import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 表情包。
///
/// 想解决的是三件事：ta能发表情、发表情时看着顺眼、以及**你从微信 / QQ
/// 复制过来的表情ta也能看懂**。
///
/// ## 为什么内置的是「表情名 → 表情符号」，而不是微信 / QQ 的那套图
///
/// 微信和 QQ 的表情图片是腾讯的资源，把别人的图打包进一个要发给朋友的 App
/// 不合适。但表情的**名字**是通用的 —— `[微笑]`、`[呲牙]`、`[捂脸]` 两家都这么叫，
/// 而 Unicode 里本来就有意思对得上的表情符号。所以：
///
/// - **默认**：`[微笑]` 显示成 😊。不用配任何东西，两边都看得懂。
/// - **想换成微信 / QQ 那套图**：设置里导入你的表情图片，
///   **文件名就是表情名**（`微笑.png` → `[微笑]`），导入之后就用你的图。
///
/// 这样既绕开了版权，也正好落在那条原则上：能交给用户自定义的，就别替他定死。
///
/// ## 分类口径（2026-10-06 改）
///
/// 老板原话：「表情包不要你那样子分类，分类的话，是**黄脸**一个那些」。
/// 所以分类改成**系统键盘那套口径**（CLDR / Apple 的 emoji 分组）：
/// 常用 / 笑脸与人物 / 动物与自然 / 食物与饮料 / 活动 / 旅行与地点 / 物件 / 符号 / 旗帜；
/// 用户自上传的「我的」单独一类、排在最前。
///
/// ⚠️ 内置的全是 **Unicode emoji 字符**，不打包任何微信 / QQ 的版权图片。
final class EmojiPack: ObservableObject {

    static let shared = EmojiPack()

    // MARK: - 一条表情

    struct Item: Identifiable, Equatable {
        /// 表情名，不含方括号 —— 就是微信里那个 `微笑`
        var name: String
        /// 对应的表情符号
        var emoji: String
        /// 自定义图片的文件名；有值就优先用图片
        var imageFile: String?
        /// 归到哪一套。内置套见 `packOrder`，用户自上传的归 `custom`。
        var packID: String = "smileys"

        var id: String { name }
        var isCustom: Bool { imageFile != nil }
    }

    // MARK: - 一套表情

    /// 一套表情。内置 9 类 + 自定义「我的」永远排最前。
    struct Pack: Identifiable {
        let id: String
        let name: String
        let isCustom: Bool
        /// 这套里的表情名（按 `items` 的顺序）。
        var names: [String]
    }

    /// 「常用」那一类。**这里的 id 故意写成 `classic`**：
    /// 面板 `EmojiPanelView` 的默认选中项是硬编码的 `"classic"`，而面板 UI 这轮
    /// 冻结不许动，所以让「常用」沿用这个 id —— 这样默认一打开就是「常用」这一类，
    /// 不用去改面板。显示名仍然是「常用」（见 `packName`）。
    static let frequentPackID = "classic"

    /// 内置套的顺序，界面按它排。
    static let packOrder: [String] = [
        frequentPackID,   // 常用
        "smileys",        // 笑脸与人物
        "animals",        // 动物与自然
        "food",           // 食物与饮料
        "activity",       // 活动
        "travel",         // 旅行与地点
        "objects",        // 物件
        "symbols",        // 符号
        "flags"           // 旗帜
    ]

    /// 套 id → 显示名。
    static func packName(_ id: String) -> String {
        switch id {
        case frequentPackID: return "常用"
        case "smileys": return "笑脸与人物"
        case "animals": return "动物与自然"
        case "food": return "食物与饮料"
        case "activity": return "活动"
        case "travel": return "旅行与地点"
        case "objects": return "物件"
        case "symbols": return "符号"
        case "flags": return "旗帜"
        case "custom": return "我的"
        default: return id
        }
    }

    /// 「常用」这一类里放哪些表情（按顺序）。**同一条表情会同时出现在「常用」
    /// 和它自己的分类里** —— 跟系统键盘的「最近使用」一个意思。
    ///
    /// 这里写的是**名字**，取的时候从已建好的 `items` 里按名字找。
    static let frequentNames: [String] = [
        "微笑", "大笑", "呲牙", "偷笑", "笑哭", "可爱", "调皮", "得意", "酷", "害羞",
        "馋", "委屈", "难过", "大哭", "捂脸", "思考", "赞", "强", "OK", "加油",
        "抱抱", "亲亲", "爱心", "心碎", "玫瑰", "礼物", "蛋糕", "咖啡", "干杯", "火",
        "太阳", "月亮", "星星", "狗头", "猫", "熊猫", "花", "拳头", "鼓掌", "握手"
    ]

    // MARK: - 内置表
    //
    // 名字取自微信和 QQ 两家的常用表情，合并成一张表（两家的名字大量重合）。
    // 三元组是 (套 id, 名字, 表情)；每名字只归一套，全是 **Unicode emoji 字符**。
    // 分类口径见文件头的说明。

    private static let builtin: [(String, String, String)] = [
        // —— 笑脸与人物（黄脸 / 手 / 人）——
        ("smileys", "微笑", "😊"), ("smileys", "大笑", "😄"), ("smileys", "呲牙", "😁"), ("smileys", "偷笑", "🤭"),
        ("smileys", "笑哭", "😂"), ("smileys", "可爱", "🥰"), ("smileys", "调皮", "😜"), ("smileys", "坏笑", "😏"),
        ("smileys", "害羞", "😊"), ("smileys", "馋", "😋"), ("smileys", "得意", "😎"), ("smileys", "酷", "😎"),
        ("smileys", "白眼", "🙄"), ("smileys", "鄙视", "😒"), ("smileys", "无语", "😑"), ("smileys", "尴尬", "😅"),
        ("smileys", "流汗", "😅"), ("smileys", "擦汗", "😓"), ("smileys", "惊恐", "😱"), ("smileys", "震惊", "😲"),
        ("smileys", "困", "😪"), ("smileys", "睡", "😴"), ("smileys", "委屈", "🥺"), ("smileys", "难过", "😔"),
        ("smileys", "失望", "😞"), ("smileys", "大哭", "😭"), ("smileys", "流泪", "😭"), ("smileys", "发怒", "😡"),
        ("smileys", "咒骂", "🤬"), ("smileys", "抓狂", "😫"), ("smileys", "晕", "😵"), ("smileys", "惊喜", "🤩"),
        ("smileys", "捂脸", "🤦"), ("smileys", "悠闲", "😌"), ("smileys", "天啊", "😱"),
        ("smileys", "疑惑", "🤔"), ("smileys", "思考", "🤔"),
        ("smileys", "花痴", "😍"), ("smileys", "亲亲", "😘"), ("smileys", "爱你", "😘"), ("smileys", "飞吻", "😘"),
        ("smileys", "害怕", "😨"), ("smileys", "微笑面对", "🙂"), ("smileys", "无奈", "😔"),
        ("smileys", "惊讶", "😮"), ("smileys", "庆祝", "🥳"), ("smileys", "抱拳", "🙏"),
        ("smileys", "合十", "🙏"), ("smileys", "握手", "🤝"), ("smileys", "鞠躬", "🙇"), ("smileys", "鼓掌", "👏"),
        ("smileys", "加油", "💪"), ("smileys", "奋斗", "💪"), ("smileys", "赞", "👍"), ("smileys", "强", "👍"),
        ("smileys", "弱", "👎"), ("smileys", "OK", "👌"), ("smileys", "拒绝", "🙅"), ("smileys", "耶", "✌️"),
        ("smileys", "胜利", "✌️"), ("smileys", "拳头", "👊"), ("smileys", "挥手", "👋"), ("smileys", "再见", "👋"),
        ("smileys", "围观", "👀"), ("smileys", "偷看", "👀"), ("smileys", "举手", "🙋"), ("smileys", "点头", "🙆"),
        ("smileys", "比心", "🫶"), ("smileys", "六六六", "🤙"), ("smileys", "抱抱", "🤗"), ("smileys", "拥抱", "🤗"),
        ("smileys", "点赞", "👍"),

        // —— 动物与自然 ——
        ("animals", "狗头", "🐶"), ("animals", "猫", "🐱"), ("animals", "狮子", "🦁"), ("animals", "猪头", "🐷"),
        ("animals", "兔子", "🐰"), ("animals", "熊猫", "🐼"), ("animals", "狐狸", "🦊"), ("animals", "青蛙", "🐸"),
        ("animals", "企鹅", "🐧"), ("animals", "小鸟", "🐦"), ("animals", "猫头鹰", "🦉"), ("animals", "独角兽", "🦄"),
        ("animals", "蜜蜂", "🐝"), ("animals", "蝴蝶", "🦋"), ("animals", "蜗牛", "🐌"), ("animals", "鱼", "🐟"),
        ("animals", "摸鱼", "🐟"), ("animals", "海豚", "🐬"), ("animals", "鲸鱼", "🐳"), ("animals", "乌龟", "🐢"),
        ("animals", "花", "🌸"), ("animals", "玫瑰", "🌹"),
        ("animals", "凋谢", "🥀"), ("animals", "向日葵", "🌻"), ("animals", "四叶草", "🍀"), ("animals", "树", "🌳"),
        ("animals", "蘑菇", "🍄"), ("animals", "叶子", "🍃"), ("animals", "火", "🔥"), ("animals", "太阳", "☀️"),
        ("animals", "月亮", "🌙"), ("animals", "月亮脸", "🌝"), ("animals", "新月脸", "🌚"), ("animals", "星星", "⭐"),
        ("animals", "闪", "✨"), ("animals", "雪花", "❄️"), ("animals", "云", "☁️"), ("animals", "雨", "🌧️"),
        ("animals", "闪电", "⚡"), ("animals", "彩虹", "🌈"), ("animals", "浪", "🌊"), ("animals", "地球", "🌍"),

        // —— 食物与饮料 ——
        ("food", "蛋糕", "🎂"), ("food", "咖啡", "☕"), ("food", "奶茶", "🧋"), ("food", "啤酒", "🍺"),
        ("food", "干杯", "🍻"), ("food", "米饭", "🍚"), ("food", "面条", "🍜"), ("food", "糖", "🍬"),
        ("food", "糖葫芦", "🍡"), ("food", "饮料", "🥤"), ("food", "香槟", "🍾"), ("food", "西瓜", "🍉"),
        ("food", "苹果", "🍎"), ("food", "葡萄", "🍇"), ("food", "草莓", "🍓"), ("food", "桃子", "🍑"),
        ("food", "菠萝", "🍍"), ("food", "玉米", "🌽"), ("food", "披萨", "🍕"), ("food", "汉堡", "🍔"),
        ("food", "薯条", "🍟"), ("food", "热狗", "🌭"), ("food", "寿司", "🍣"), ("food", "饺子", "🥟"),
        ("food", "冰淇淋", "🍦"), ("food", "甜甜圈", "🍩"), ("food", "饼干", "🍪"), ("food", "巧克力", "🍫"),
        ("food", "爆米花", "🍿"), ("food", "鸡蛋", "🥚"), ("food", "奶酪", "🧀"), ("food", "面包", "🍞"),
        ("food", "鸡腿", "🍗"), ("food", "牛排", "🥩"), ("food", "葡萄酒", "🍷"), ("food", "牛奶", "🥛"),

        // —— 活动 ——
        ("activity", "足球", "⚽"), ("activity", "篮球", "🏀"), ("activity", "乒乓", "🏓"), ("activity", "羽毛球", "🏸"),
        ("activity", "网球", "🎾"), ("activity", "台球", "🎱"), ("activity", "跑步", "🏃"), ("activity", "骑车", "🚴"),
        ("activity", "游泳", "🏊"), ("activity", "滑雪", "🎿"), ("activity", "爬山", "🧗"), ("activity", "举重", "🏋️"),
        ("activity", "瑜伽", "🧘"), ("activity", "跳舞", "💃"), ("activity", "唱歌", "🎤"), ("activity", "吉他", "🎸"),
        ("activity", "钢琴", "🎹"), ("activity", "打鼓", "🥁"), ("activity", "小号", "🎺"), ("activity", "游戏手柄", "🎮"),
        ("activity", "骰子", "🎲"), ("activity", "奖杯", "🏆"), ("activity", "奖牌", "🏅"), ("activity", "冠军", "🥇"),
        ("activity", "派对", "🎉"), ("activity", "烟花", "🎆"), ("activity", "气球", "🎈"), ("activity", "礼物", "🎁"),
        ("activity", "靶心", "🎯"), ("activity", "电影", "🎬"), ("activity", "画画", "🎨"), ("activity", "圣诞树", "🎄"),

        // —— 旅行与地点 ——
        ("travel", "飞机", "✈️"), ("travel", "火箭", "🚀"), ("travel", "汽车", "🚗"), ("travel", "出租车", "🚕"),
        ("travel", "公交车", "🚌"), ("travel", "火车", "🚆"), ("travel", "高铁", "🚄"), ("travel", "地铁", "🚇"),
        ("travel", "自行车", "🚲"), ("travel", "摩托车", "🏍️"), ("travel", "船", "🚢"), ("travel", "帆船", "⛵"),
        ("travel", "直升机", "🚁"), ("travel", "飞碟", "🛸"), ("travel", "滑板", "🛹"), ("travel", "地图", "🗺️"),
        ("travel", "指南针", "🧭"), ("travel", "帐篷", "⛺"), ("travel", "山", "⛰️"), ("travel", "雪山", "🏔️"),
        ("travel", "火山", "🌋"), ("travel", "沙滩", "🏖️"), ("travel", "海岛", "🏝️"), ("travel", "城市", "🏙️"),
        ("travel", "桥", "🌉"), ("travel", "摩天轮", "🎡"), ("travel", "过山车", "🎢"), ("travel", "自由女神", "🗽"),
        ("travel", "城堡", "🏰"), ("travel", "房子", "🏠"),

        // —— 物件 ——
        ("objects", "手机", "📱"), ("objects", "电脑", "💻"), ("objects", "键盘", "⌨️"), ("objects", "鼠标", "🖱️"),
        ("objects", "电话", "☎️"), ("objects", "灯泡", "💡"), ("objects", "电池", "🔋"), ("objects", "插头", "🔌"),
        ("objects", "相机", "📷"), ("objects", "电视", "📺"), ("objects", "手表", "⌚"), ("objects", "闹钟", "⏰"),
        ("objects", "锤子", "🔨"), ("objects", "扳手", "🔧"), ("objects", "刀", "🔪"), ("objects", "炸弹", "💣"),
        ("objects", "盾", "🛡️"), ("objects", "钥匙", "🔑"), ("objects", "锁", "🔒"), ("objects", "放大镜", "🔍"),
        ("objects", "药丸", "💊"), ("objects", "书", "📖"),
        ("objects", "文件夹", "📁"), ("objects", "日历", "📅"), ("objects", "邮件", "✉️"), ("objects", "包裹", "📦"),
        ("objects", "钱", "💰"), ("objects", "信用卡", "💳"), ("objects", "购物车", "🛒"), ("objects", "剪刀", "✂️"),
        ("objects", "眼镜", "👓"), ("objects", "雨伞", "☂️"), ("objects", "王冠", "👑"), ("objects", "戒指", "💍"),
        ("objects", "口红", "💄"), ("objects", "背包", "🎒"), ("objects", "鞋子", "👟"), ("objects", "垃圾桶", "🗑️"),

        // —— 符号 ——
        ("symbols", "爱心", "❤️"), ("symbols", "橙心", "🧡"), ("symbols", "黄心", "💛"), ("symbols", "绿心", "💚"),
        ("symbols", "蓝心", "💙"), ("symbols", "紫心", "💜"), ("symbols", "黑心", "🖤"), ("symbols", "白心", "🤍"),
        ("symbols", "心碎", "💔"), ("symbols", "闪心", "💖"), ("symbols", "对勾", "✅"),
        ("symbols", "叉", "❌"), ("symbols", "疑问", "❓"), ("symbols", "感叹", "❗"), ("symbols", "警告", "⚠️"),
        ("symbols", "禁止", "🚫"), ("symbols", "闪闪", "💫"), ("symbols", "钻石", "💎"), ("symbols", "音乐", "🎵"),
        ("symbols", "音符", "🎶"), ("symbols", "喇叭", "📢"), ("symbols", "静音", "🔇"), ("symbols", "铃铛", "🔔"),
        ("symbols", "加", "➕"), ("symbols", "减", "➖"), ("symbols", "100分", "💯"), ("symbols", "无限", "♾️"),
        ("symbols", "循环", "🔄"), ("symbols", "回收", "♻️"),

        // —— 旗帜 ——
        ("flags", "白旗", "🏳️"), ("flags", "彩虹旗", "🏳️🌈"), ("flags", "黑旗", "🏴"), ("flags", "海盗旗", "🏴☠️"),
        ("flags", "红旗", "🚩"), ("flags", "终点旗", "🏁"), ("flags", "中国", "🇨🇳"), ("flags", "美国", "🇺🇸"),
        ("flags", "日本旗", "🇯🇵"), ("flags", "韩国", "🇰🇷"), ("flags", "英国", "🇬🇧"), ("flags", "法国", "🇫🇷"),
        ("flags", "德国", "🇩🇪"), ("flags", "意大利", "🇮🇹"), ("flags", "西班牙", "🇪🇸"), ("flags", "俄罗斯", "🇷🇺"),
        ("flags", "加拿大", "🇨🇦"), ("flags", "澳大利亚", "🇦🇺"), ("flags", "巴西", "🇧🇷"), ("flags", "新加坡", "🇸🇬")
    ]

    // MARK: - 状态

    /// 关掉之后 `[微笑]` 就原样显示，一个字符都不改。
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }

    /// 内置 + 自定义，界面上按这个顺序列。
    @Published private(set) var items: [Item] = []

    /// 最近一次导入的结果，给界面显示。
    @Published var statusLine: String?

    /// 名字 → 自定义图片文件名
    @Published private(set) var custom: [String: String] = [:]

    private var index: [String: Item] = [:]

    #if canImport(UIKit)
    /// 图片读一次就留着 —— 表情网格一屏十几个，每次读盘会卡。
    private var imageCache: [String: UIImage] = [:]
    #endif

    private static let enabledKey = "aevis.emojiEnabled"
    private static let customKey = "aevis.customEmoji"

    /// 表情名的长度上限。太长的方括号内容大概率是正文，不是表情。
    private static let nameLimit = 8

    private static let pattern = try? NSRegularExpression(pattern: "\\[([^\\[\\]]{1,12})\\]")

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if let saved = UserDefaults.standard.dictionary(forKey: Self.customKey) as? [String: String] {
            custom = saved
        }
        rebuild()
    }

    // MARK: - 组装

    private func rebuild() {
        var list: [Item] = []
        var table: [String: Item] = [:]
        var used = Set<String>()

        for (packID, name, emoji) in Self.builtin where !used.contains(name) {
            used.insert(name)
            // 同名导过图就用图
            let item = Item(name: name, emoji: emoji, imageFile: custom[name], packID: packID)
            list.append(item)
            table[name] = item
        }

        // 用户自己导入的、内置表里没有的，接在后面（归「我的」）
        for (name, file) in custom.sorted(by: { $0.key < $1.key }) where !used.contains(name) {
            used.insert(name)
            let item = Item(name: name, emoji: "🖼️", imageFile: file, packID: "custom")
            list.append(item)
            table[name] = item
        }

        items = list
        index = table
    }

    /// 内置表情的条数（界面拿来说"内置了多少个"）。
    static var builtinCount: Int { builtin.count }

    /// 全部套：自定义「我的」永远在最前，其后是 9 个内置分类。
    var packs: [Pack] {
        var result: [Pack] = [
            Pack(id: "custom", name: Self.packName("custom"), isCustom: true,
                 names: items(inPack: "custom").map(\.name))
        ]
        result.append(contentsOf: Self.packOrder.map { id in
            Pack(id: id, name: Self.packName(id), isCustom: false,
                 names: items(inPack: id).map(\.name))
        })
        return result
    }

    /// 按套取表情；`query` 非空时再按名字模糊过滤（空串返回全套）。
    ///
    /// 特殊：「常用」这一类不按 `packID` 取，而是从**所有**表情里挑出常被用到的
    /// 那批（见 `frequentNames`）—— 跟系统键盘的「最近使用」一个意思：同一条表情
    /// 既在「常用」里，也在它自己的分类里。
    func items(inPack id: String, matching query: String = "") -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if id == Self.frequentPackID {
            var byName: [String: Item] = [:]
            for item in items { byName[item.name] = item }
            var result = Self.frequentNames.compactMap { byName[$0] }
            if !trimmed.isEmpty {
                result = result.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
            }
            return result
        }

        var result = items.filter { $0.packID == id }
        if !trimmed.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        }
        return result
    }

    func lookup(_ name: String) -> Item? {
        index[name]
    }

    // MARK: - 渲染

    /// 把正文里的 `[表情名]` 换成真正的表情符号。
    ///
    /// 只换**认得的**名字：不认得的方括号内容原样留着 ——
    /// 你正常打字写到方括号时不该被动手脚。
    /// 导了图片的那些**不在这里换**（混排图文用 Text 做不了），
    /// 留给「整条是单个表情」那条路径去渲染成图。
    func render(_ text: String) -> String {
        guard enabled, text.contains("["), let pattern = Self.pattern else { return text }

        let source = text as NSString
        let matches = pattern.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0

        for match in matches {
            let name = source.substring(with: match.range(at: 1))
            guard let item = lookup(name), item.imageFile == nil else { continue }
            output += source.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            output += item.emoji
            cursor = match.range.location + match.range.length
        }

        output += source.substring(from: cursor)
        return output
    }

    /// 整条消息就是一个表情？返回它 —— 界面会**放大显示**（微信那种大表情）。
    ///
    /// 两种情况都算：整条写的是 `[微笑]`，或者整条就是一个表情符号。
    func single(in text: String) -> Item? {
        guard enabled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // ① 整条就是 [名字]
        if trimmed.count <= Self.nameLimit + 2,
           trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            let name = String(trimmed.dropFirst().dropLast())
            if !name.contains("["), !name.contains("]"), let item = lookup(name) {
                return item
            }
        }

        // ② 整条就是一串表情符号
        let scalars = Array(trimmed.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 8 else { return nil }
        let onlyEmoji = scalars.allSatisfy { scalar in
            scalar.properties.isEmoji
                || scalar.properties.isJoinControl
                || scalar.value == 0xFE0F
                || scalar.value == 0xFE0E
        }
        guard onlyEmoji, scalars.contains(where: { $0.properties.isEmojiPresentation }) else {
            return nil
        }
        return Item(name: trimmed, emoji: trimmed, imageFile: nil)
    }

    // MARK: - 自定义图片

    /// 存图片的目录：`Documents/Emoji/`
    private var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Emoji", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func imageURL(for item: Item) -> URL? {
        guard let file = item.imageFile else { return nil }
        return directory.appendingPathComponent(file)
    }

    #if canImport(UIKit)
    func image(for item: Item) -> UIImage? {
        guard let file = item.imageFile else { return nil }
        if let cached = imageCache[file] { return cached }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
              let loaded = UIImage(data: data) else { return nil }
        imageCache[file] = loaded
        return loaded
    }

    /// 统一落盘：UIImage → PNG 重编码 → `名字.png`。
    /// 覆盖 iPhone HEIC 等「苹果上传特殊性」—— 落盘一律 PNG，之后渲染不挑格式。
    static func savePNG(_ image: UIImage, name: String, into directory: URL) -> String? {
        guard let data = image.pngData() else { return nil }
        let file = "\(name).png"
        let target = directory.appendingPathComponent(file)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try data.write(to: target)
        } catch {
            return nil
        }
        return file
    }
    #endif

    /// 导入一批表情图片。**文件名就是表情名** —— `微笑.png` 对应 `[微笑]`。
    /// 统一重编码成 PNG 落盘（覆盖 HEIC 等格式），返回成功和失败各一批。
    @discardableResult
    func importImages(from urls: [URL]) -> (added: [String], failed: [String]) {
        var added: [String] = []
        var failed: [String] = []

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let name = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= Self.nameLimit, !name.contains("[") else {
                failed.append("\(url.lastPathComponent)（名字太长或有特殊符号）")
                continue
            }

            guard let data = try? Data(contentsOf: url) else {
                failed.append("\(url.lastPathComponent)（读不出来）")
                continue
            }

            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                failed.append("\(url.lastPathComponent)（不是图片）")
                continue
            }
            guard let file = Self.savePNG(image, name: name, into: directory) else {
                failed.append("\(url.lastPathComponent)（存不进去）")
                continue
            }
            custom[name] = file
            imageCache[file] = nil
            added.append(name)
            #else
            failed.append("\(url.lastPathComponent)（这台设备不支持图片）")
            #endif
        }

        if !added.isEmpty {
            UserDefaults.standard.set(custom, forKey: Self.customKey)
            rebuild()
        }

        return (added, failed)
    }

    /// 一行一个图床 URL，批量导入成表情。
    /// URL 最后一段文件名（去扩展名）= 表情名；下载 → 解码 → PNG 重编码 → 落盘。
    ///
    /// ⚠️ `@MainActor`：`URLSession` 的下载在它自己的线程上，`await` 回来之后
    /// 这里继续在**主线程**改 `custom` / `rebuild()` —— 后台改 @Published 在 iOS 26 会硬崩。
    @MainActor
    func importRemoteURLs(_ lines: [String]) async -> (added: [String], failed: [String]) {
        var added: [String] = []
        var failed: [String] = []

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let url = URL(string: trimmed), url.host != nil else {
                failed.append("\(trimmed)（不是有效的网址）")
                continue
            }

            let rawName = url.deletingPathExtension().lastPathComponent
            let name = (rawName.removingPercentEncoding ?? rawName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= Self.nameLimit,
                  !name.contains("["), !name.contains("]") else {
                failed.append("\(trimmed)（名字太长或有特殊符号）")
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    failed.append("\(name)（下载失败）")
                    continue
                }

                #if canImport(UIKit)
                guard let image = UIImage(data: data) else {
                    failed.append("\(name)（不是图片）")
                    continue
                }
                guard let file = Self.savePNG(image, name: name, into: directory) else {
                    failed.append("\(name)（存不进去）")
                    continue
                }
                custom[name] = file
                imageCache[file] = nil
                added.append(name)
                #else
                failed.append("\(name)（这台设备不支持图片）")
                #endif
            } catch {
                failed.append("\(name)（下载失败：\(error.localizedDescription)）")
            }
        }

        if !added.isEmpty {
            UserDefaults.standard.set(custom, forKey: Self.customKey)
            rebuild()
        }

        return (added, failed)
    }

    /// 删掉一个自定义表情，回到内置的那个符号。
    func removeCustom(_ name: String) {
        guard let file = custom[name] else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        #if canImport(UIKit)
        imageCache[file] = nil
        #endif
        custom[name] = nil
        UserDefaults.standard.set(custom, forKey: Self.customKey)
        rebuild()
    }

    /// 把导入的表情全部清掉。
    func removeAllCustom() {
        for (_, file) in custom {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            #if canImport(UIKit)
            imageCache[file] = nil
            #endif
        }
        custom = [:]
        UserDefaults.standard.set([String: String](), forKey: Self.customKey)
        rebuild()
    }

    // MARK: - 给ta看的说明

    /// 拼进系统提示词的一段话 —— 不告诉ta规矩，ta就会乱用。
    /// 按用户设置的「表情发送频率」给出三档不同的话。
    ///
    /// ⚠️ **一定要把库里有什么原样列出来**（见 `inventory`）。
    ///    用户 2026-10-01 的原话：「你要让他去使用表情包库。**如果有的话就发出来，
    ///    没有的话就不发**」。
    ///    以前这里只举了「[微笑]、[呲牙]」两个例子，于是ta只会发这两个 ——
    ///    库里明明有一百多个，ta一个都不会用。而且ta**不知道什么名字是没有的**，
    ///    会现编一个「[无语]」「[汗]」出来，渲染时匹配不到，方括号就原样显示在气泡里。
    ///
    /// ⚠️ 同样是**实例**属性（要读 `items`）。调用处是
    ///    `EmojiPack.shared.promptNote` —— 别改回 static。
    var promptNote: String {
        let list = inventory
        let lead: String
        switch AppSettings.shared.emojiFrequency {
        case .rarely:
            lead = "你很少发表情，偶尔特别想表达时才发一个。"
        case .moderate:
            lead = "你想发表情的时候可以发。整条只写一个表情会放大显示；别每句都带。"
        case .always:
            lead = "你几乎每句话都想带一个表情，让聊天更生动。"
        }

        guard !list.isEmpty else {
            return lead + "但你现在没有任何可用的表情，所以别发方括号表情，"
                + "也别用「[xx]」这种写法 —— 发了也显示不出来。"
        }

        return """
        \(lead)
        发法：在话里写上方括号包住的名字，比如 [微笑]。名字必须从下面这份清单里挑，
        清单里没有的名字一个都别写 —— 写了不会变成表情，只会把「[xxx]」这几个字
        原样显示出来，很难看。

        你可以用的表情（括号里是它的分类）：
        \(list)

        挑最贴你此刻心情的那个用，别老是同一个；也别为了发表情而发表情 ——
        该好好说话的时候就好好说话。
        """
    }

    /// 库里所有**现在真的能渲染出东西**的表情名 + 分类，按名字排好、逗号分隔。
    ///
    /// 内置的几百个加上用户自己导入的，一份给模型看的清单。
    /// 注意这里读的是 `items`（已经过 `rebuild()`），所以用户删掉的内置表情
    /// 不会出现在清单里 —— ta不会去发一个发不出来的名字。
    ///
    /// ⚠️ 是**实例**属性不是 `static` —— `items` 挂在单例上，写成 static 取不到它
    ///    （CI 上就是这么挂的：`instance member 'items' cannot be used on type`）。
    var inventory: String {
        items
            .map { "\($0.name)（\(Self.packName($0.packID))）" }
            .sorted()
            .joined(separator: "、")
    }
}
