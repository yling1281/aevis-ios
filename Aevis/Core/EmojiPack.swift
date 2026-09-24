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

        var id: String { name }
        var isCustom: Bool { imageFile != nil }
    }

    // MARK: - 内置表
    //
    // 名字取自微信和 QQ 两家的常用表情。两家的名字本来就大量重合
    // （`[微笑]` `[呲牙]` `[大哭]` 这些是一样的），所以合并成一张表。

    private static let builtin: [(String, String)] = [
        ("微笑", "😊"), ("大笑", "😄"), ("呲牙", "😁"), ("偷笑", "🤭"),
        ("害羞", "😊"), ("憨笑", "😄"), ("可爱", "🥰"), ("调皮", "😜"),
        ("吐舌", "😝"), ("馋", "😋"), ("得意", "😎"), ("酷", "😎"),
        ("坏笑", "😏"), ("勾引", "😏"), ("傲慢", "😤"), ("白眼", "🙄"),
        ("鄙视", "😒"), ("无语", "😑"), ("尴尬", "😅"), ("流汗", "😅"),
        ("擦汗", "😓"), ("冷汗", "😰"), ("惊恐", "😱"), ("震惊", "😲"),
        ("发呆", "😳"), ("困", "😪"), ("睡", "😴"), ("哈欠", "🥱"),
        ("委屈", "🥺"), ("可怜", "🥺"), ("难过", "😔"), ("失望", "😞"),
        ("苦涩", "😖"), ("快哭了", "😖"), ("大哭", "😭"), ("流泪", "😭"),
        ("心碎", "💔"), ("裂开", "💔"), ("发怒", "😡"), ("咒骂", "🤬"),
        ("抓狂", "😫"), ("折磨", "😩"), ("晕", "😵"), ("疯了", "🤪"),
        ("骷髅", "💀"), ("闭嘴", "🤐"), ("嘘", "🤫"), ("疑问", "❓"),
        ("思考", "🤔"), ("惊喜", "🤩"), ("激动", "🤩"), ("期待", "🥰"),
        ("爱心", "❤️"), ("示爱", "❤️"), ("爱你", "😘"), ("亲亲", "😘"),
        ("飞吻", "😘"), ("抱抱", "🤗"), ("拥抱", "🤗"), ("握手", "🤝"),
        ("合十", "🙏"), ("鞠躬", "🙇"), ("磕头", "🙇"), ("比心", "🫶"),
        ("鼓掌", "👏"), ("加油", "💪"), ("奋斗", "💪"), ("强壮", "💪"),
        ("强", "👍"), ("赞", "👍"), ("弱", "👎"), ("差劲", "👎"),
        ("OK", "👌"), ("好的", "👌"), ("明白", "👌"), ("拒绝", "🙅"),
        ("耶", "✌️"), ("胜利", "✌️"), ("抱拳", "🙏"), ("拳头", "👊"),
        ("挥手", "👋"), ("再见", "👋"), ("回头", "👀"), ("偷看", "👀"),
        ("围观", "👀"), ("吃瓜", "🍉"), ("摸鱼", "🐟"), ("捂脸", "🤦"),
        ("撇嘴", "😖"), ("囧", "😅"), ("抠鼻", "🤧"), ("悠闲", "😌"),
        ("哭笑不得", "😂"), ("狗头", "🐶"), ("旺柴", "🐶"), ("打脸", "🫲"),
        ("天啊", "😱"), ("哇", "😲"), ("六六六", "🤙"), ("嗯哼", "😤"),
        ("玫瑰", "🌹"), ("凋谢", "🥀"), ("太阳", "☀️"), ("月亮", "🌙"),
        ("星星", "⭐"), ("闪电", "⚡"), ("炸弹", "💣"), ("礼物", "🎁"),
        ("蛋糕", "🎂"), ("咖啡", "☕"), ("奶茶", "🧋"), ("啤酒", "🍺"),
        ("干杯", "🍻"), ("饭", "🍚"), ("猪头", "🐷"), ("便便", "💩"),
        ("刀", "🔪"), ("足球", "⚽"), ("篮球", "🏀"), ("乒乓", "🏓"),
        ("转圈", "🌀"), ("发抖", "🥶"), ("火", "🔥"), ("敲打", "🔨"),
        ("吃面", "🍜"), ("吃糖", "🍬"), ("饮料", "🥤"), ("香槟", "🍾"),
        ("泳池", "🏊"), ("跑步", "🏃"), ("骑车", "🚴"), ("飞机", "✈️"),
        ("月亮脸", "🌚"), ("笑脸", "🌝"), ("菜刀", "🔪"), ("药丸", "💊"),
        ("困倦", "😩"), ("不耐烦", "😒"), ("微笑面对", "🙂"), ("扶额", "🤦"),
        ("嘿嘿", "😁"), ("嘿嘿嘿", "😏"), ("装死", "🙃"), ("倒立", "🙃"),
        ("小手", "🤚"), ("举手", "🙋"), ("拒绝三连", "🙅"), ("点头", "🙆")
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

        for (name, emoji) in Self.builtin where !used.contains(name) {
            used.insert(name)
            // 同名导过图就用图
            let item = Item(name: name, emoji: emoji, imageFile: custom[name])
            list.append(item)
            table[name] = item
        }

        // 用户自己导入的、内置表里没有的，接在后面
        for (name, file) in custom.sorted(by: { $0.key < $1.key }) where !used.contains(name) {
            used.insert(name)
            let item = Item(name: name, emoji: "🖼️", imageFile: file)
            list.append(item)
            table[name] = item
        }

        items = list
        index = table
    }

    /// 内置表情的条数（界面拿来说"内置了多少个"）。
    static var builtinCount: Int { builtin.count }

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
    #endif

    /// 导入一批表情图片。**文件名就是表情名** —— `微笑.png` 对应 `[微笑]`。
    ///
    /// 返回成功和失败各一批，界面把它们分别说清楚（失败不能闷着不说）。
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
            guard UIImage(data: data) != nil else {
                failed.append("\(url.lastPathComponent)（不是图片）")
                continue
            }
            #endif

            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
            let file = "\(name).\(ext)"
            let target = directory.appendingPathComponent(file)

            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try data.write(to: target)
            } catch {
                failed.append("\(url.lastPathComponent)（存不进去）")
                continue
            }

            custom[name] = file
            #if canImport(UIKit)
            imageCache[file] = nil
            #endif
            added.append(name)
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
    static let promptNote = """
    你想发表情的时候，可以像微信那样写方括号里的名字，比如 [微笑]、[呲牙]、[偷笑]、[大哭]。
    整条消息只写一个表情是可以的，那样会放大显示。
    别每句都带，正常说话就行。
    """
}
