import Foundation

#if canImport(EventKit)
import EventKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// 一个能被她调用的工具。
/// `parameters` 是给模型看的 JSON Schema，`run` 是真正干活的实现。
struct DeviceTool {
    let name: String
    let title: String
    let description: String
    let parameters: [String: Any]
    let run: ([String: Any]) async -> String
}

/// TA 的手。
///
/// 这些工具会被发给模型（function calling），由她自己决定什么时候用、用什么参数。
/// 每个工具都只做一件小事，而且**只读她能读的东西**——
/// 日历、提醒这类要用户授权的，授权被拒就老老实实返回「没授权」，绝不假装成功。
enum DeviceTools {

    // MARK: - 登记

    /// 她全部的手 = App 自带的 + 外接的。
    ///
    /// **所有链路都走这里**（打字聊天、语音通话、一起听、主动消息、朋友圈），
    /// 所以外接的 MCP 工具接一次就处处可用 —— 包括你直接对她说话的时候。
    static func all() -> [DeviceTool] {
        builtinTools + MCPStore.shared.bridgedTools
    }

    /// App 自带的那些，不含 MCP。
    ///
    /// 单独拆出来是有原因的：`MCPStore.bridgedTools` 判重时要看这些名字，
    /// 如果它去调 `all()`，就绕回来变成无限递归了（真会崩栈）。
    static var builtinTools: [DeviceTool] {
        [timeTool, clipboardReadTool, clipboardWriteTool, calculatorTool,
         calendarListTool, calendarCreateTool, reminderCreateTool]
        + senseTools
        + webTools
        + musicTools
        + momentTools
        + panTools
        + qqTools
        + systemTools
        + [shellTool]
    }

    /// 发给模型的工具定义（OpenAI function calling 格式）。
    static func definitions() -> [[String: Any]] {
        all().map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                ]
            ]
        }
    }

    static func title(for name: String) -> String {
        all().first(where: { $0.name == name })?.title ?? name
    }

    static func run(name: String, arguments: [String: Any]) async -> String {
        guard let tool = all().first(where: { $0.name == name }) else {
            return "没有叫「\(name)」的工具。"
        }
        return await tool.run(arguments)
    }

    // MARK: - 时间

    private static var timeTool: DeviceTool {
        DeviceTool(
            name: "get_current_time",
            title: "看了眼时间",
            description: """
            读取这台设备当前的日期、时间、星期、时区、UTC 偏移和时间戳。
            用户问「今天几号」「现在几点」「今天星期几」这类问题时，必须用它，
            不要凭自己的感觉回答 —— 你不知道今天是哪天。
            """,
            parameters: emptyParameters()
        ) { _ in
            let now = Date()
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "zh_CN")

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm:ss"

            let timezone = TimeZone.current
            let offsetSeconds = timezone.secondsFromGMT(for: now)
            let offsetHours = Double(offsetSeconds) / 3600.0
            let sign = offsetHours >= 0 ? "+" : ""

            return """
            本地时间：\(formatter.string(from: now))
            时区：\(timezone.identifier)（UTC\(sign)\(offsetHours)）
            UTC 时间：\(ISO8601DateFormatter().string(from: now))
            时间戳：\(Int(now.timeIntervalSince1970))
            """
        }
    }

    // MARK: - 剪贴板

    private static var clipboardReadTool: DeviceTool {
        DeviceTool(
            name: "read_clipboard",
            title: "看了下剪贴板",
            description: """
            读取用户剪贴板里当前的文字。用户说「我复制的那个」「剪贴板里」时用它。
            注意：系统可能会弹出「允许粘贴」的询问，那一次由用户自己决定。
            """,
            parameters: emptyParameters()
        ) { _ in
            #if canImport(UIKit)
            let text = UIPasteboard.general.string ?? ""
            if text.isEmpty {
                return "剪贴板是空的，或者里面不是文字。"
            }
            return "剪贴板内容：\n\(text)"
            #else
            return "当前平台不支持剪贴板。"
            #endif
        }
    }

    private static var clipboardWriteTool: DeviceTool {
        DeviceTool(
            name: "write_clipboard",
            title: "往剪贴板放了个东西",
            description: "把一段文字放进用户的剪贴板，方便他直接粘贴到别处。",
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "要放进剪贴板的文字"]
                ],
                "required": ["text"]
            ]
        ) { args in
            #if canImport(UIKit)
            guard let text = args["text"] as? String, !text.isEmpty else {
                return "没给要复制的文字。"
            }
            UIPasteboard.general.string = text
            return "已经把 \(text.count) 个字符放进剪贴板了。"
            #else
            return "当前平台不支持剪贴板。"
            #endif
        }
    }

    // MARK: - 计算器

    private static var calculatorTool: DeviceTool {
        DeviceTool(
            name: "calculate",
            title: "算了一道题",
            description: """
            计算数学表达式，支持 + - * / 和括号、小数。
            用户让你算数、算账、算比例时用它，不要心算 —— 心算容易错。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "expression": ["type": "string", "description": "要算的表达式，例如 (128*3+56)/4"]
                ],
                "required": ["expression"]
            ]
        ) { args in
            guard let raw = args["expression"] as? String else { return "没给表达式。" }
            guard let tokens = tokenize(raw) else { return "表达式里只能有数字和 + - * / ( ) 。" }
            var position = 0
            guard let value = evaluate(tokens, &position), position == tokens.count else {
                return "这个表达式算不出来，检查一下括号和符号。"
            }
            let display = value == value.rounded() && abs(value) < 1e15
                ? String(Int64(value))
                : String(format: "%.6g", value)
            return "\(raw.trimmingCharacters(in: .whitespaces)) = \(display)"
        }
    }

    /// 自己写一个小解析器，不用 NSExpression ——
    /// 后者遇到畸形表达式会抛 ObjC 异常直接崩，风险太大。
    private static func tokenize(_ input: String) -> [String]? {
        var tokens: [String] = []
        var number = ""
        for character in input {
            if character.isNumber || character == "." {
                number.append(character)
            } else if "+-*/()".contains(character) {
                if !number.isEmpty { tokens.append(number); number = "" }
                tokens.append(String(character))
            } else if character != " " {
                return nil
            }
        }
        if !number.isEmpty { tokens.append(number) }
        return tokens.isEmpty ? nil : tokens
    }

    private static func evaluate(_ tokens: [String], _ position: inout Int) -> Double? {
        guard var left = evaluateTerm(tokens, &position) else { return nil }
        while position < tokens.count, tokens[position] == "+" || tokens[position] == "-" {
            let op = tokens[position]
            position += 1
            guard let right = evaluateTerm(tokens, &position) else { return nil }
            left = op == "+" ? left + right : left - right
        }
        return left
    }

    private static func evaluateTerm(_ tokens: [String], _ position: inout Int) -> Double? {
        guard var left = evaluateFactor(tokens, &position) else { return nil }
        while position < tokens.count, tokens[position] == "*" || tokens[position] == "/" {
            let op = tokens[position]
            position += 1
            guard let right = evaluateFactor(tokens, &position) else { return nil }
            if op == "/" && right == 0 { return nil }
            left = op == "*" ? left * right : left / right
        }
        return left
    }

    private static func evaluateFactor(_ tokens: [String], _ position: inout Int) -> Double? {
        guard position < tokens.count else { return nil }
        let token = tokens[position]

        if token == "-" {
            position += 1
            return evaluateFactor(tokens, &position).map { -$0 }
        }
        if token == "(" {
            position += 1
            guard let value = evaluate(tokens, &position) else { return nil }
            guard position < tokens.count, tokens[position] == ")" else { return nil }
            position += 1
            return value
        }
        guard let value = Double(token) else { return nil }
        position += 1
        return value
    }

    // MARK: - 日历与提醒

    #if canImport(EventKit)
    private static let eventStore = EKEventStore()

    private static func authorizedEvents() async -> EKEventStore? {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            return granted ? eventStore : nil
        } catch {
            return nil
        }
    }

    private static func authorizedReminders() async -> EKEventStore? {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            return granted ? eventStore : nil
        } catch {
            return nil
        }
    }
    #endif

    private static var calendarListTool: DeviceTool {
        DeviceTool(
            name: "list_calendar_events",
            title: "翻了翻你的日历",
            description: """
            读取用户接下来的日历日程。用户问「我明天有什么安排」「这周忙不忙」时用它。
            参数 days 表示往后看几天，默认 7。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "days": ["type": "integer", "description": "往后看几天，1~30，默认 7"]
                ],
                "required": [] as [String]
            ]
        ) { args in
            #if canImport(EventKit)
            guard let store = await authorizedEvents() else {
                return "用户没有授权访问日历，我看不到。可以让他去「设置 → 隐私与安全性 → 日历」里给 Aevis 打开。"
            }
            let days = min(max((args["days"] as? Int) ?? 7, 1), 30)
            let start = Date()
            guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
                return "时间范围不对。"
            }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else {
                return "接下来 \(days) 天日历上是空的。"
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEE HH:mm"
            let lines = events.prefix(20).map { event in
                "- \(formatter.string(from: event.startDate))  \(event.title ?? "（没写标题）")"
            }
            return "接下来 \(days) 天有 \(events.count) 件事：\n" + lines.joined(separator: "\n")
            #else
            return "当前平台不支持日历。"
            #endif
        }
    }

    private static var calendarCreateTool: DeviceTool {
        DeviceTool(
            name: "create_calendar_event",
            title: "往你的日历里加了一条",
            description: """
            在用户的日历里新建一条日程。用户说「提醒我明天下午三点开会」这种要落到日历的，
            用它。start 用 ISO8601 格式，例如 2026-09-25T15:00:00。
            """
            ,
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "日程标题"],
                    "start": ["type": "string", "description": "开始时间，ISO8601，例如 2026-09-25T15:00:00"],
                    "duration_minutes": ["type": "integer", "description": "持续多少分钟，默认 60"],
                    "notes": ["type": "string", "description": "备注，可以不给"]
                ],
                "required": ["title", "start"]
            ]
        ) { args in
            #if canImport(EventKit)
            guard let store = await authorizedEvents() else {
                return "用户没有授权访问日历，我写不进去。"
            }
            guard let title = args["title"] as? String, !title.isEmpty else {
                return "缺少日程标题。"
            }
            guard let startText = args["start"] as? String, let start = parseDate(startText) else {
                return "开始时间看不懂。需要 ISO8601，例如 2026-09-25T15:00:00。"
            }
            let minutes = min(max((args["duration_minutes"] as? Int) ?? 60, 5), 24 * 60)

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = start.addingTimeInterval(Double(minutes) * 60)
            event.notes = args["notes"] as? String
            event.calendar = store.defaultCalendarForNewEvents

            do {
                try store.save(event, span: .thisEvent)
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "M月d日 EEE HH:mm"
                return "已经写进日历：\(title)，\(formatter.string(from: start))，\(minutes) 分钟。"
            } catch {
                return "写日历失败：\(error.localizedDescription)"
            }
            #else
            return "当前平台不支持日历。"
            #endif
        }
    }

    private static var reminderCreateTool: DeviceTool {
        DeviceTool(
            name: "create_reminder",
            title: "替你记了一件事",
            description: """
            在「提醒事项」里新建一条待办。用户说「提醒我买牛奶」「记一下」这类时用它。
            due 可以不给；给了就用 ISO8601 格式。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "要提醒的事"],
                    "due": ["type": "string", "description": "截止时间，ISO8601，可以不给"],
                    "notes": ["type": "string", "description": "备注，可以不给"]
                ],
                "required": ["title"]
            ]
        ) { args in
            #if canImport(EventKit)
            guard let store = await authorizedReminders() else {
                return "用户没有授权访问提醒事项，我记不进去。"
            }
            guard let title = args["title"] as? String, !title.isEmpty else {
                return "缺少要提醒的内容。"
            }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.notes = args["notes"] as? String
            reminder.calendar = store.defaultCalendarForNewReminders()
            if let dueText = args["due"] as? String, let due = parseDate(dueText) {
                reminder.dueDateComponents = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: due
                )
            }
            do {
                try store.save(reminder, commit: true)
                return "记好了：\(title)"
            } catch {
                return "写提醒失败：\(error.localizedDescription)"
            }
            #else
            return "当前平台不支持提醒事项。"
            #endif
        }
    }

    // MARK: - 零件

    /// 无参数工具的 schema。别的文件（SenseTools）也要用，所以不能是 private。
    static func emptyParameters() -> [String: Any] {
        [
            "type": "object",
            "properties": [:] as [String: Any],
            "required": [] as [String]
        ]
    }

    /// 模型给的时间可能是 ISO8601，也可能是「2026-09-25 15:00」这种，都试一遍。
    static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed) { return date }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}
