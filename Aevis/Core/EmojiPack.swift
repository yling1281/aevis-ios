import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 表情包。
///
/// 想解决的是三件事：她能发表情、发表情时看着顺眼、以及**你从微信 / QQ
/// 复制过来的表情她也能看懂**。
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
        /// 归到哪一套（经典 / 心情 / 恋爱 / 动物日常 / 搞怪 / 我的）。
        var packID: String = "classic"

        var id: String { name }
        var isCustom: Bool { imageFile != nil }
    }

    // MARK: - 一套表情

    /// 一套表情。内置 5 套 + 自定义「我的」永远最后。
    struct Pack: Identifiable {
        let id: String
        let name: String
        let isCustom: Bool
        /// 这套里的表情名（按 `items` 的顺序）。
        var names: [String]
    }

    /// 内置套的顺序，界面按它排。
    static let packOrder: [String] = ["classic", "mood", "love", "animal", "silly"]

    /// 套 id → 显示名。
    static func packName(_ id: String) -> String {
        switch id {
        case "classic": return "经典"
        case "mood": return "心情"
        case "love": return "恋爱"
        case "animal": return "动物日常"
        case "silly": return "搞怪"
        case "custom": return "我的"
        default: return id
        }
    }

    // MARK: - 内置表
    //
    // 名字取自微信和 QQ 两家的常用表情。两家的名字本来就大量重合
    // （`[微笑]` `[呲牙]` `[大哭]` 这些是一样的），所以合并成一张表。
    // 三元组是 (套 id, 名字, 表情)；每名字只归一套，总数 148。

    private static let builtin: [(String, String, String)] = [
        // —— 经典 ——
        ("classic", "微笑", "😊"), ("classic", "大笑", "😄"), ("classic", "呲牙", "😁"), ("classic", "偷笑", "🤭"),
        ("classic", "害羞", "😊"), ("classic", "憨笑", "😄"), ("classic", "可爱", "🥰"), ("classic", "调皮", "😜"),
        ("classic", "疑问", "❓"), ("classic", "思考", "🤔"), ("classic", "握手", "🤝"), ("classic", "合十", "🙏"),
        ("classic", "鞠躬", "🙇"), ("classic", "鼓掌", "👏"), ("classic", "加油", "💪"), ("classic", "奋斗", "💪"),
        ("classic", "强壮", "💪"), ("classic", "强", "👍"), ("classic", "赞", "👍"), ("classic", "弱", "👎"),
        ("classic", "差劲", "👎"), ("classic", "OK", "👌"), ("classic", "好的", "👌"), ("classic", "明白", "👌"),
        ("classic", "拒绝", "🙅"), ("classic", "耶", "✌️"), ("classic", "胜利", "✌️"), ("classic", "抱拳", "🙏"),
        ("classic", "拳头", "👊"), ("classic", "挥手", "👋"), ("classic", "再见", "👋"), ("classic", "回头", "👀"),
        ("classic", "围观", "👀"), ("classic", "哭笑不得", "😂"), ("classic", "太阳", "☀️"), ("classic", "月亮", "🌙"),
        ("classic", "星星", "⭐"), ("classic", "闪电", "⚡"), ("classic", "礼物", "🎁"), ("classic", "蛋糕", "🎂"),
        ("classic", "咖啡", "☕"), ("classic", "奶茶", "🧋"), ("classic", "啤酒", "🍺"), ("classic", "干杯", "🍻"),
        ("classic", "饭", "🍚"), ("classic", "足球", "⚽"), ("classic", "篮球", "🏀"), ("classic", "乒乓", "🏓"),
        ("classic", "火", "🔥"), ("classic", "吃面", "🍜"), ("classic", "吃糖", "🍬"), ("classic", "饮料", "🥤"),
        ("classic", "香槟", "🍾"), ("classic", "泳池", "🏊"), ("classic", "跑步", "🏃"), ("classic", "骑车", "🚴"),
        ("classic", "飞机", "✈️"), ("classic", "笑脸", "🌝"), ("classic", "药丸", "💊"), ("classic", "微笑面对", "🙂"),
        ("classic", "小手", "🤚"), ("classic", "举手", "🙋"), ("classic", "拒绝三连", "🙅"), ("classic", "点头", "🙆"),
        // —— 心情 ——
        ("mood", "馋", "😋"), ("mood", "得意", "😎"), ("mood", "酷", "😎"), ("mood", "傲慢", "😤"),
        ("mood", "白眼", "🙄"), ("mood", "鄙视", "😒"), ("mood", "无语", "😑"), ("mood", "尴尬", "😅"),
        ("mood", "流汗", "😅"), ("mood", "擦汗", "😓"), ("mood", "冷汗", "😰"), ("mood", "惊恐", "😱"),
        ("mood", "震惊", "😲"), ("mood", "发呆", "😳"), ("mood", "困", "😪"), ("mood", "睡", "😴"),
        ("mood", "哈欠", "🥱"), ("mood", "委屈", "🥺"), ("mood", "可怜", "🥺"), ("mood", "难过", "😔"),
        ("mood", "失望", "😞"), ("mood", "苦涩", "😖"), ("mood", "快哭了", "😖"), ("mood", "大哭", "😭"),
        ("mood", "流泪", "😭"), ("mood", "发怒", "😡"), ("mood", "咒骂", "🤬"), ("mood", "抓狂", "😫"),
        ("mood", "折磨", "😩"), ("mood", "晕", "😵"), ("mood", "惊喜", "🤩"), ("mood", "激动", "🤩"),
        ("mood", "捂脸", "🤦"), ("mood", "撇嘴", "😖"), ("mood", "囧", "😅"), ("mood", "悠闲", "😌"),
        ("mood", "天啊", "😱"), ("mood", "哇", "😲"), ("mood", "嗯哼", "😤"), ("mood", "发抖", "🥶"),
        ("mood", "困倦", "😩"), ("mood", "不耐烦", "😒"), ("mood", "扶额", "🤦"),
        // —— 恋爱 ——
        ("love", "心碎", "💔"), ("love", "期待", "🥰"), ("love", "爱心", "❤️"), ("love", "示爱", "❤️"),
        ("love", "爱你", "😘"), ("love", "亲亲", "😘"), ("love", "飞吻", "😘"), ("love", "抱抱", "🤗"),
        ("love", "拥抱", "🤗"), ("love", "比心", "🫶"), ("love", "玫瑰", "🌹"), ("love", "凋谢", "🥀"),
        // —— 动物日常 ——
        ("animal", "摸鱼", "🐟"), ("animal", "狗头", "🐶"), ("animal", "旺柴", "🐶"), ("animal", "猪头", "🐷"),
        // —— 搞怪 ——
        ("silly", "吐舌", "😝"), ("silly", "坏笑", "😏"), ("silly", "勾引", "😏"), ("silly", "裂开", "💔"),
        ("silly", "疯了", "🤪"), ("silly", "骷髅", "💀"), ("silly", "闭嘴", "🤐"), ("silly", "嘘", "🤫"),
        ("silly", "磕头", "🙇"), ("silly", "偷看", "👀"), ("silly", "吃瓜", "🍉"), ("silly", "抠鼻", "🤧"),
        ("silly", "打脸", "🫲"), ("silly", "六六六", "🤙"), ("silly", "炸弹", "💣"), ("silly", "便便", "💩"),
        ("silly", "刀", "🔪"), ("silly", "转圈", "🌀"), ("silly", "敲打", "🔨"), ("silly", "月亮脸", "🌚"),
        ("silly", "菜刀", "🔪"), ("silly", "嘿嘿", "😁"), ("silly", "嘿嘿嘿", "😏"), ("silly", "装死", "🙃"),
        ("silly", "倒立", "🙃")
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

    /// 全部套：5 内置套按顺序 + 「我的」永远最后。
    var packs: [Pack] {
        var result = Self.packOrder.map { id in
            Pack(id: id, name: Self.packName(id), isCustom: false, names: items(inPack: id).map(\.name))
        }
        result.append(
            Pack(id: "custom", name: Self.packName("custom"), isCustom: true,
                 names: items(inPack: "custom").map(\.name))
        )
        return result
    }

    /// 按套取表情；`query` 非空时再按名字模糊过滤（空串返回全套）。
    func items(inPack id: String, matching query: String = "") -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: - 给她看的说明

    /// 拼进系统提示词的一段话 —— 不告诉她规矩，她就会乱用。
    /// 按用户设置的「表情发送频率」给出三档不同的话。
    static var promptNote: String {
        switch AppSettings.shared.emojiFrequency {
        case .rarely:
            return "你很少发表情，偶尔特别想表达时才发一个方括号表情，比如 [微笑]。"
        case .moderate:
            return "你想发表情时可以写方括号里的名字，比如 [微笑]、[呲牙]。整条只写一个表情会放大显示。别每句都带。"
        case .always:
            return "你几乎每句话都想带一个方括号表情，比如 [微笑]、[偷笑]，让聊天更生动。"
        }
    }
}
