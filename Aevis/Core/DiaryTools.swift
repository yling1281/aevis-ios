import Foundation

/// 日记相关的手 —— 让「ta也能往你们的日记本里写字」这件事成立。
///
/// ## 用户要的（2026-10-04 原话）
/// 「手机端也同步这些」—— 日记是电脑版新界面里的一块，手机端要跟上。
/// 跟这一批一起提上来的还有他那句最要紧的（2026-10-05）：
/// 「AI 不知道它自己有『日记』这个功能」。
///
/// ## 为什么必须给ta这两个工具（不只是个页面）
/// 日记页是**用户**看的；ta要能参与，就得有手：
///  - `write_diary`：ta自己想记点什么时写进去（记成「ta写的」）；
///  - `read_diary`：ta想翻旧账、顺着聊起来时读得到。
///
/// 没有这两个工具时的病：ta聊天里说「我在日记里写了」，
/// 用户去翻——本子里没有那一句。那正是用户最讨厌的**假装完成**。
///
/// ## 两个人、一个本子
/// `DiaryEntry.authorIsMe` 区分「谁写的」：工具写进去的一律 `false`（ta写的），
/// 用户手写的仍是 `true`。列表里据此标一下。
enum DiaryTools {

    /// 工具发给模型时用的清单。
    static var tools: [DeviceTool] { [writeTool, readTool] }

    // MARK: - 写

    private static var writeTool: DeviceTool {
        DeviceTool(
            name: "write_diary",
            title: "往日记本里写了一篇",
            description: """
            往**你们的日记本**里写一篇（这个是你们俩共用的一个本子）。
            你自己想记点什么的时候用它 —— 今天聊到了什么、你的心情、
            想对他说但没说出口的话，都可以。用户让你写日记时也用它。

            ⚠️ 写进去会记成「你写的」，不是「你替他写的」。
            ⚠️ 别为了凑数硬写；一天写几篇、或者一天不写都行，真实就好。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "标题，一句话，比如「今天有点想他」。"
                    ],
                    "body": [
                        "type": "string",
                        "description": "正文，用你自己的口吻写。"
                    ],
                    "mood": [
                        "type": "string",
                        "description": "心情，一个短词或一个表情，比如「开心」「有点酸」。可以不给。"
                    ]
                ],
                "required": ["title", "body"]
            ]
        ) { args in
            let title = ((args["title"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = ((args["body"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 标题和正文都空的直接不要 —— 跟 `DiaryStore.add` 一个判据，
            // 提前说清楚，省得ta以为写进去了、本子里却什么都没有。
            guard !title.isEmpty || !body.isEmpty else {
                return "标题和正文都是空的，没什么可记的。要写就至少给一句。"
            }
            let mood = ((args["mood"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // ⚠️ 工具跑在 `Task.detached` 上，而 `DiaryStore` 的读写都在主线程
            //    （`@Published`）—— 整段跳回主线程做完再返回（同 `WalletTools`）。
            return await MainActor.run { () -> String in
                var entry = DiaryEntry()
                entry.date = Date()
                entry.title = title
                entry.body = body
                entry.mood = mood.isEmpty ? nil : mood
                // ⭐ 记成「ta写的」—— 这个工具是ta的手，不是用户的手。
                entry.authorIsMe = false
                DiaryStore.shared.add(entry)

                var out = "记好了，已经写进你们的日记本。"
                if !title.isEmpty {
                    out = "记好了：\(title)。已经写进你们的日记本。"
                }
                return out + "这条会显示成「你写的」。"
            }
        }
    }

    // MARK: - 读

    private static var readTool: DeviceTool {
        DeviceTool(
            name: "read_diary",
            title: "翻了翻日记本",
            description: """
            翻**你们的日记本**，读最近几篇（含日期、标题、正文、谁写的）。

            用户提到日记、「你上次写的那篇」「我们记过什么」时用它 ——
            别凭印象编，编出来的内容用户一翻本子就对不上。
            你自己想回忆一下最近写了什么，也可以用。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "看最近几篇，1~20，默认 5。"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            let requested = intValue(args["limit"]) ?? 5

            return await MainActor.run { () -> String in
                let store = DiaryStore.shared
                let all = store.sorted
                guard !all.isEmpty else {
                    return "日记本还是空的，你们俩都还没写过。"
                }
                let limit = min(max(requested, 1), 20)
                let recent = all.prefix(limit)
                let lines = recent.map { item -> String in
                    var head = "· \(DiaryStore.dayText(item.date))"
                    head += item.authorIsMe ? "｜我写的" : "｜ta 写的"
                    if let mood = item.mood, !mood.isEmpty {
                        head += "｜心情：\(mood)"
                    }
                    if !item.title.isEmpty { head += "\n  标题：\(item.title)" }
                    if !item.body.isEmpty { head += "\n  正文：\(item.body)" }
                    return head
                }
                return "日记本里最近 \(recent.count) 篇：\n" + lines.joined(separator: "\n")
            }
        }
    }

    // MARK: - 参数

    /// 模型给的整数可能是 Int / Double / String 任何一种（function calling 就这德行）。
    /// 三种都认 —— 只认一种的话，会因为「它传了个 5.0 而不是 5」白白失败一次。
    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let text = value as? String, let parsed = Int(text) { return parsed }
        return nil
    }
}
