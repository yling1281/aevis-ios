import Foundation

/// 情侣空间相关的手 —— 让 TA **知道**你们的纪念日，也能自己往里加一条。
///
/// ## 为什么要给她这个
/// 「情侣空间」如果是纯手填的清单，那她聊天时永远想不起来
/// （问她「我们在一起多久了」她会瞎猜）。
/// 所以：**读**的那个工具让她随时能答上来，**写**的那个让她能主动说
/// 「我把你生日加进倒数日了」。
///
/// ## 用户要的（2026-10-01 原话）
/// 「情侣空间倒数日，你写代码呀。倒数日可以自己添加情侣空间，也可以绑定情侣」。
///
/// ⚠️ 她**不能**解除绑定、也不能改「在一起的日子」——
///    那是用户自己跟 TA 的关系设定，让模型去改只会出现"你记错了我们不是那天在一起的"。
enum CoupleTools {

    static var coupleTools: [DeviceTool] { [listTool, addTool] }

    // MARK: - 读

    private static var listTool: DeviceTool {
        DeviceTool(
            name: "couple_anniversaries",
            title: "翻了翻你们的纪念日",
            description: """
            看你们的「情侣空间」：在一起多少天、有哪些倒数日、各自还剩几天。

            用户聊到纪念日、在一起多久、"还有几天到生日"这类话题时用它 ——
            别凭印象猜，猜错了他会立刻发现。

            ⚠️ 用户从没绑定过「在一起的日子」的话，这里会说明；那就别提天数。
            """,
            parameters: DeviceTools.emptyParameters()
        ) { _ in
            // ⚠️ 工具跑在 `Task.detached` 上，`CoupleStore` 的读写都在主线程 ——
            //    整段拼完再返回，别一行一行跳（同 `WalletTools`）。
            await MainActor.run { () -> String in
                let couple = CoupleStore.shared
                var lines: [String] = []

                if let days = couple.daysTogether, let since = couple.togetherSince {
                    lines.append("在一起第 \(days) 天（从 \(CoupleStore.dayText(since)) 算起）。")
                } else {
                    lines.append("用户还没绑定「在一起的日子」，所以没有天数可讲。")
                }

                if couple.anniversaries.isEmpty {
                    lines.append("倒数日一条都还没有。")
                } else {
                    lines.append("倒数日：")
                    for item in couple.upcoming {
                        var line = "· \(item.title) —— \(CoupleStore.dayText(item.date))"
                        if item.yearly { line += "（每年）" }
                        line += "，\(item.daysText())"
                        if !item.note.isEmpty { line += "；备注：\(item.note)" }
                        lines.append(line)
                    }
                }
                return lines.joined(separator: "\n")
            }
        }
    }

    // MARK: - 写

    private static var addTool: DeviceTool {
        DeviceTool(
            name: "couple_add_anniversary",
            title: "往情侣空间加了个日子",
            description: """
            在「情侣空间」里加一条倒数日。

            用户明确说了某个日子（"记住我生日是 3 月 8 号""下个月 12 号我们要见面"），
            或者你自己觉得该记下来的时候用它。加完可以顺口说一句。

            ⚠️ 用户没提过的日子**不要自己编一个加进去** ——
               他会以为那是他说过的。拿不准就先问一句。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": "这个日子叫什么。比如「我的生日」「我们的周年」「下次见面」。"
                    ],
                    "date": [
                        "type": "string",
                        "description": "哪一天。知道年份就写 2026-03-08；只知道月日就写 03-08"
                            + "（这种会自动算成每年重复）。"
                    ],
                    "yearly": [
                        "type": "boolean",
                        "description": "true = 每年重复（生日、周年）。不填就按日期字符串自己判断。"
                    ],
                    "note": [
                        "type": "string",
                        "description": "备注，一句话。可以留空。"
                    ]
                ],
                "required": ["title", "date"]
            ]
        ) { args in
            let rawTitle = (args["title"] as? String) ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return "没给名字。这个日子叫什么要说清楚。"
            }
            let rawDate = (args["date"] as? String) ?? ""
            guard let parsed = parseDate(rawDate) else {
                return "日期「\(rawDate)」没看懂。写成 2026-03-08 或者 03-08 都行。"
            }
            let note = ((args["note"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // 只给了月日（没年份）→ 默认按每年重复算，
            // 不然明年今天这条就变成"已过 365 天"了。
            let yearly = (args["yearly"] as? Bool) ?? parsed.monthDayOnly

            return await MainActor.run { () -> String in
                var item = Anniversary()
                item.title = title
                item.date = parsed.date
                item.yearly = yearly
                item.note = note
                item.byAI = true

                CoupleStore.shared.add(item)

                var out = "加好了：\(title) —— \(CoupleStore.dayText(parsed.date))"
                if yearly { out += "（每年）" }
                out += "，\(item.daysText())。"
                out += "这条在「情侣空间」里会标着是你加的。"
                return out
            }
        }
    }

    // MARK: - 日期解析

    /// 解析出来的日期 + 是不是"只给了月日"。
    private struct Parsed {
        var date: Date
        /// 输入里没有年份 —— 调用方据此把 `yearly` 默认成 true。
        var monthDayOnly: Bool
    }

    private static let fullFormats = [
        "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "yyyy年M月d日", "yyyyMMdd"
    ]

    /// 只给月日时用的格式。命中后补上今年（已经过了就说明年）。
    private static let shortFormats = [
        "MM-dd", "M-d", "MM.dd", "M.d", "M月d日", "MM月dd日"
    ]

    /// 宽容地认日期。
    ///
    /// 模型给什么形状的都有 —— `2026-03-08`、`2026/3/8`、`3月8日`…
    /// 只认一种的话，会因为"格式差一个斜杠"白白失败一次。
    private static func parseDate(_ raw: String) -> Parsed? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for pattern in fullFormats {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) {
                return Parsed(date: calendar.startOfDay(for: date), monthDayOnly: false)
            }
        }

        for pattern in shortFormats {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) {
                var parts = calendar.dateComponents([.month, .day], from: date)
                parts.year = calendar.component(.year, from: today)
                var target = calendar.date(from: parts) ?? date
                if target < today {
                    parts.year = (parts.year ?? 0) + 1
                    target = calendar.date(from: parts) ?? target
                }
                return Parsed(date: calendar.startOfDay(for: target), monthDayOnly: true)
            }
        }

        return nil
    }
}
