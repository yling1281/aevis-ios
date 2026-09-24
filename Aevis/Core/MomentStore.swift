import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 朋友圈里的一条评论。
struct MomentComment: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var author: Moment.Author
    var text: String
    var createdAt: Date = Date()
}

/// 一条朋友圈动态。
struct Moment: Codable, Identifiable, Equatable {
    /// 谁发的。这个 App 里只有两个人，所以不做用户系统。
    enum Author: String, Codable {
        case me
        case ta

        var isMe: Bool { self == .me }
    }

    var id: String = UUID().uuidString
    var author: Author = .ta
    var text: String = ""
    /// 图片存在单独的文件里，只在 JSON 里留个文件名 —— 不然存档会被图片撑爆。
    var imageName: String?
    var createdAt: Date = Date()
    var likes: [Author] = []
    var comments: [MomentComment] = []

    var hasImage: Bool { imageName != nil }
}

/// 朋友圈。
///
/// 设计取舍：
/// - **只存两个作者**（我 / TA）。没有好友系统，也不需要。
/// - **图片走文件**，JSON 里只留文件名。
/// - 她发动态**不做定时器**（后台跑不了模型），而是每次打开 App 时按「距上一条多久」补发。
/// - 她也能**在聊天里被要求发**（工具 `post_moment`），说了就真发，不假装。
final class MomentStore: ObservableObject {
    static let shared = MomentStore()

    @Published private(set) var moments: [Moment] = []
    @Published private(set) var working = false
    @Published var statusLine: String?

    private let fileURL: URL
    private let imageDirectory: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-moments.json")

        imageDirectory = base.appendingPathComponent("AevisMoments", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)

        load()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Moment].self, from: data) else {
            return
        }
        moments = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(moments) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 图片

    func imageURL(for moment: Moment) -> URL? {
        guard let name = moment.imageName else { return nil }
        let url = imageDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func image(for moment: Moment) -> UIImage? {
        #if canImport(UIKit)
        guard let url = imageURL(for: moment), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
        #else
        return nil
        #endif
    }

    /// 存一张图，返回文件名。压到最长边 1400 —— 手机上看足够，又不至于占地方。
    @discardableResult
    func storeImage(_ image: UIImage, maxSide: CGFloat = 1400, quality: CGFloat = 0.82) -> String? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = scaled.jpegData(compressionQuality: quality) else { return nil }

        let name = UUID().uuidString + ".jpg"
        try? data.write(to: imageDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    // MARK: - 增删

    @discardableResult
    func post(text: String, author: Moment.Author, image: UIImage? = nil) -> Moment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return nil }

        var moment = Moment(author: author, text: trimmed)
        if let image {
            moment.imageName = storeImage(image)
        }
        moments.insert(moment, at: 0)
        save()
        return moment
    }

    func remove(_ moment: Moment) {
        if let name = moment.imageName {
            try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(name))
        }
        moments.removeAll { $0.id == moment.id }
        save()
    }

    func toggleLike(_ moment: Moment) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        if let existing = moments[index].likes.firstIndex(of: .me) {
            moments[index].likes.remove(at: existing)
        } else {
            moments[index].likes.append(.me)
        }
        save()
    }

    /// 指定谁来点赞。已经点过就不重复。
    func like(_ moment: Moment, by author: Moment.Author) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        guard !moments[index].likes.contains(author) else { return }
        moments[index].likes.append(author)
        save()
    }

    func unlike(_ moment: Moment, by author: Moment.Author) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index].likes.removeAll { $0 == author }
        save()
    }

    /// 某人在一条动态下评论了几条。
    func commentCount(on moment: Moment, by author: Moment.Author) -> Int {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return 0 }
        return moments[index].comments.filter { $0.author == author }.count
    }

    /// 「我上一次评论之后，她回了几条」——
    /// 回她的条数上限按这个算，这样我每留一条言她就能回，但不会连着自言自语。
    func taCommentsAfterMyLastComment(on moment: Moment) -> Int {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return 0 }
        let comments = moments[index].comments
        let lastMine = comments.lastIndex { $0.author == .me }
        guard let lastMine else { return comments.filter { $0.author == .ta }.count }
        return comments[(lastMine + 1)...].filter { $0.author == .ta }.count
    }

    func comment(_ text: String, on moment: Moment, author: Moment.Author) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index].comments.append(MomentComment(author: author, text: trimmed))
        save()
    }

    func removeComment(_ comment: MomentComment, from moment: Moment) {
        guard let index = moments.firstIndex(where: { $0.id == moment.id }) else { return }
        moments[index].comments.removeAll { $0.id == comment.id }
        save()
    }

    func clear() {
        for moment in moments {
            if let name = moment.imageName {
                try? FileManager.default.removeItem(at: imageDirectory.appendingPathComponent(name))
            }
        }
        moments.removeAll()
        save()
        statusLine = "朋友圈清空了。"
    }

    // MARK: - 给她看

    /// 最近几条动态的文字版，喂给她当上下文用。
    func digest(limit: Int = 6) -> String {
        guard !moments.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"

        let lines = moments.prefix(limit).map { moment in
            var line = "[\(formatter.string(from: moment.createdAt))] "
                + (moment.author.isMe ? "对方" : "你") + "发了：\(moment.text)"
            if moment.likes.contains(.me) { line += "（对方点了赞）" }
            for comment in moment.comments {
                line += "\n    \(comment.author.isMe ? "对方" : "你")评论：\(comment.text)"
            }
            return line
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 让她发

    /// 让她写一条动态。返回没发出去就 nil。
    @discardableResult
    func generateAndPost(persona: Persona, config: LLMConfig, memory: [String], image: UIImage? = nil) async -> Moment? {
        let text = await compose(persona: persona, config: config, memory: memory)
        guard !text.isEmpty else { return nil }
        return post(text: text, author: .ta, image: image)
    }

    /// 让她按人设写一条。写不出来返回空串（调用方决定要不要退回兜底句）。
    func compose(persona: Persona, config: LLMConfig, memory: [String]) async -> String {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.fallbackLines.randomElement() ?? ""
        }

        var instruction = """
        发一条朋友圈。就像平时刷到的那种，一两句话，不要标题、不要话题标签、不要表情符号堆砌。
        可以是一点心情、一件小事、一句没头没尾的念叨。
        如果是晚上，可以提睡觉；如果是早上，可以提起床。别每次都一样。
        直接输出内容本身，不要引号，不要解释。
        """
        let recent = digest(limit: 3)
        if !recent.isEmpty {
            instruction += "\n\n你最近发过的（别重复）：\n\(recent)"
        }

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: instruction)],
                memory: memory
            ) {
                collected += piece
                if collected.count > 400 { break }
            }
        } catch {
            return ""
        }

        // 模型偶尔会带引号或「朋友圈：」这种前缀，清掉
        var text = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in ["朋友圈：", "朋友圈:", "「", "」", "\""] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 我发完之后：她自动来互动

    /// 我发了动态 → 她来点赞 + 评论。
    ///
    /// 点赞和评论都受设置控制，而且**评论条数有上限** ——
    /// 一口气刷十条比没人理还烦。
    func reactToMyMoment(moment: Moment, persona: Persona, config: LLMConfig, memory: [String]) async {
        let settings = AppSettings.shared
        guard settings.momentAutoReact else { return }

        if settings.momentLikeMine {
            like(moment, by: .ta)
        }

        let allowance = settings.momentMaxComments - commentCount(on: moment, by: .ta)
        guard allowance > 0 else { return }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let instruction = """
        对方刚发了一条朋友圈：

        「\(moment.text)」

        用你自己的身份，在他的动态下面评论，就像平时刷到朋友发的动态那样。
        最多写 \(allowance) 条，**一条一行**，每条短一点（十几个字以内）。
        不要解释、不要引号、不要编号，直接写评论内容本身。
        """

        let lines = await composeLines(
            instruction: instruction,
            persona: persona,
            config: config,
            memory: memory,
            limit: allowance,
            characterBudget: 400
        )
        for line in lines {
            comment(line, on: moment, author: .ta)
        }

        // 「有些还会私信主动联系你」—— 评完评论，有时候她还会直接发消息来。
        await maybeSendDirectMessage(
            reason: "对方刚发了一条动态：「\(moment.text)」，你在下面评论了",
            persona: persona,
            config: config,
            memory: memory
        )
    }

    /// 让她写几句，按行拆开、清理、按上限截断。
    private func composeLines(
        instruction: String,
        persona: Persona,
        config: LLMConfig,
        memory: [String],
        limit: Int,
        characterBudget: Int
    ) async -> [String] {
        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: [ChatMessage(role: .user, text: instruction)],
                memory: memory
            ) {
                collected += piece
                if collected.count > characterBudget { break }
            }
        } catch {
            return []
        }
        return Self.cleanLines(collected, limit: limit)
    }

    /// 模型输出的行常常带 `- `、`1.`、「」这些东西，清掉。
    /// 太长的（超过 40 字）也丢掉 —— 那多半是它把解释也写进来了。
    static func cleanLines(_ raw: String, limit: Int) -> [String] {
        let cleaned = raw
            .split(separator: "\n")
            .map { cleanLine(String($0)) }
            .filter { !$0.isEmpty && $0.count <= 40 }

        return Array(cleaned.prefix(limit))
    }

    /// 清掉一行前面的列表符号、编号、左引号，以及末尾的右引号。
    ///
    /// 两个坑（都是对拍测试时发现的）：
    /// 1. **不能先 trim 再替换 `"- "`** —— `"- "` trim 完只剩 `"-"`，
    ///    再去匹配 `"- "` 就匹配不上，会留下一个光秃秃的横杠当评论。
    /// 2. **编号要连着点号一起删**，不能见数字就删 ——
    ///    否则「300 块有点贵」会被啃成「00 块有点贵」。
    private static func cleanLine(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)

        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            let before = text

            text = text.trimmingCharacters(in: .whitespaces)
            if let first = text.first, "-*•·「\"'#".contains(first) {
                text.removeFirst()
                continue
            }
            // 形如 "1." / "2、" / "3)" 的编号
            let digits = text.prefix { $0.isNumber }
            if !digits.isEmpty,
               let next = text.dropFirst(digits.count).first,
               next == "." || next == "、" || next == ")" {
                text = String(text.dropFirst(digits.count + 1))
                continue
            }

            if text == before { break }
        }

        text = text.trimmingCharacters(in: .whitespaces)
        // 末尾只去掉右引号这类，别把正常的标点也吃掉
        while let last = text.last, "」\"'".contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 她回复我的评论。
    ///
    /// 条数上限用「我上一次留言之后她回了几条」来算 ——
    /// 这样我每留一条言她都会回，但不会自己对着自己一直说。
    func replyToMyComment(on moment: Moment, myComment: String, persona: Persona, config: LLMConfig, memory: [String]) async {
        let settings = AppSettings.shared
        guard settings.momentAutoReply else { return }
        guard taCommentsAfterMyLastComment(on: moment) < max(1, settings.momentMaxReplies) else { return }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let instruction = """
        对方在你发的这条朋友圈下面评论了。

        你发的内容：\(moment.text)
        对方的评论：\(myComment)

        用一两句话回他，就像在朋友圈里回评论那样。直接输出回复内容，不要引号。
        """

        let lines = await composeLines(
            instruction: instruction,
            persona: persona,
            config: config,
            memory: memory,
            limit: max(1, settings.momentMaxReplies) - taCommentsAfterMyLastComment(on: moment),
            characterBudget: 300
        )
        guard let first = lines.first else { return }
        comment(first, on: moment, author: .ta)

        // 回完评论，有时候她会直接私聊过来
        await maybeSendDirectMessage(
            reason: "你自己发过：「\(moment.text)」。对方在下面评论：「\(myComment)」，你刚回了「\(first)」",
            persona: persona,
            config: config,
            memory: memory
        )
    }

    // MARK: - 私信

    /// 该不该私信。抽成纯函数是为了能单独验 ——
    /// 概率这种逻辑写错了没人看得出来（要么从不发，要么每次都发）。
    static func shouldSendDirectMessage(chance: Double, roll: Double) -> Bool {
        guard chance > 0 else { return false }
        return roll < min(chance, 1.0)
    }

    /// 她刷到之后**直接私聊**我，而不是只在评论区说。
    ///
    /// 用户原话：「有些还会私信主动联系你」—— 重点是「有些」，
    /// 所以按概率来，不是每次都发。真发出去的时候还会走一趟 Bark（如果开了）。
    func maybeSendDirectMessage(reason: String, persona: Persona, config: LLMConfig, memory: [String]) async {
        let settings = AppSettings.shared
        guard settings.momentDMEnabled else { return }
        guard Self.shouldSendDirectMessage(
            chance: settings.momentDMChance,
            roll: Double.random(in: 0..<1)
        ) else { return }
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 她正在打字的时候不插 —— 会把她半句话顶乱
        guard ChatStore.shared.canReceiveProactive else { return }

        let instruction = """
        背景：\(reason)

        现在你想直接私聊对方说一句 —— 不在评论区，而是发消息给他。
        像真人突然想起来就发了一条那样：短，一句话，口语，可以有情绪。
        不要引号，不要解释，不要提「评论」「动态」这些词，直接写你要发的那句话。
        """

        let lines = await composeLines(
            instruction: instruction,
            persona: persona,
            config: config,
            memory: memory,
            limit: 1,
            characterBudget: 200
        )
        guard let text = lines.first else { return }
        guard ChatStore.shared.appendProactive(text) else { return }

        statusLine = "她私信你了。"

        // 她主动找你的时候，值得推一条 —— 不然 App 没开就错过了
        if settings.barkEnabled, !settings.barkURL.isEmpty {
            try? await ProactiveService.shared.sendBark(
                text: text,
                title: persona.name.isEmpty ? "Aevis" : persona.name,
                urlString: settings.barkURL
            )
        }
    }

    // MARK: - 自动发

    /// 她上一条动态距今多久。
    func timeSinceLastPost() -> TimeInterval? {
        guard let last = moments.first(where: { $0.author == .ta }) else { return nil }
        return Date().timeIntervalSince(last.createdAt)
    }

    /// 打开 App 时补发。
    /// 真实定时做不到（后台跑不了模型），所以用「距上一条够久了就补一条」的办法，
    /// 效果上接近「她一直在发」。
    func catchUpIfNeeded(persona: Persona, config: LLMConfig, memory: [String]) async {
        let settings = AppSettings.shared
        guard settings.momentsEnabled, !working else { return }

        let perDay = max(1, min(settings.momentsPerDay, 6))
        let interval = 24.0 * 3600.0 / Double(perDay)

        if let elapsed = timeSinceLastPost(), elapsed < interval { return }

        working = true
        defer { working = false }

        // 一次打开最多补一条 —— 用户出去几天再回来，不该被一次性刷屏
        guard await generateAndPost(persona: persona, config: config, memory: memory) != nil else {
            // 模型用不了（没填 Key / 网络不通）时至少放一句兜底，
            // 别让朋友圈永远是空的 —— 但只在一条都没有的时候放。
            if moments.first(where: { $0.author == .ta }) == nil {
                post(text: Self.fallbackLines.randomElement() ?? "", author: .ta)
            }
            return
        }
        statusLine = "她刚发了一条朋友圈。"
    }

    /// 没配模型、或生成失败时的兜底。
    static let fallbackLines: [String] = [
        "今天风有点大，吹得人清醒",
        "刚煮了面，加了两个蛋",
        "有点困，但还是不想睡",
        "路过一家店，想起一个人",
        "什么都没干，也挺好",
        "今天走了很多路，脚有点酸"
    ]
}
