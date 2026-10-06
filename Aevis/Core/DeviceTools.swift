import Foundation

#if canImport(EventKit)
import EventKit
#endif

#if canImport(UIKit)
import UIKit
#endif

/// 一个能被ta调用的工具。
/// `parameters` 是给模型看的 JSON Schema，`run` 是真正干活的实现。
struct DeviceTool {
    let name: String
    let title: String
    let description: String
    let parameters: [String: Any]
    var category: ToolCategory = .core
    let run: ([String: Any]) async -> String
}

/// 「AI 权限」给工具分的类。
///
/// 用户 2026-09-30：「AI 拥有操控这个手机的全部功能。当然，你拥有最高权限，
/// 可以控制它开或者不开」→ 问他要哪种形态，他选了 **总开关 + 分类开关**。
///
/// ⚠️ 分类**集中维护**在 `DeviceTools.allGroups` 那张表里，不散落在各工具定义上。
///    理由是"漏一个"的代价不对称：漏掉一个**安全的**分类只是少一个开关；
///    漏掉一个**敏感的**分类，就是"用户以为关掉了、其实那个能力还在"。
enum ToolCategory: String, CaseIterable, Identifiable {
    case core
    case calendar
    case sense
    case web
    case music
    case moment
    case diary
    case pan
    case qq
    case system
    case wallet
    case couple
    case companion
    case mcp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .core: return "时间 / 计算 / 剪贴板"
        case .calendar: return "日历与提醒"
        case .sense: return "定位 / 天气 / 健康"
        case .web: return "上网搜索与看网页"
        case .music: return "音乐与一起听"
        case .moment: return "朋友圈"
        case .diary: return "日记"
        case .pan: return "百度网盘"
        case .qq: return "QQ"
        case .system: return "系统动作"
        case .wallet: return "钱包"
        case .couple: return "情侣空间"
        case .companion: return "\(Pronoun.current)主动申请的事"
        case .mcp: return "外接能力（MCP）"
        }
    }

    var detail: String {
        switch self {
        case .core: return "看时间、算数、读写剪贴板"
        case .calendar: return "翻日程、建日程、记提醒"
        case .sense: return "你在哪、什么天气、步数心率睡眠"
        case .web: return "搜索、把网页读出来"
        case .music: return "搜歌放歌、一起听、看歌词"
        case .moment: return "发朋友圈、翻朋友圈"
        case .diary: return "写日记、翻日记（两个人在一个本子里）"
        case .pan: return "读你百度网盘里的文件"
        case .qq: return "在 QQ 上回消息"
        case .system: return "锁屏、跑快捷指令、看你的屏幕、回主屏、跑命令行"
        case .wallet: return "看余额、往你钱包里打钱（只能给，不能拿）"
        case .couple: return "看纪念日、往里加倒数日"
        case .companion: return "申请给你打电话 / 看屏幕 / 一起听（真正开始还要你点头）"
        case .mcp: return "你自己接进来的那些工具"
        }
    }

    /// 敏感的那些 —— 界面上标一下，让用户在关之前知道它有多能干。
    var isSensitive: Bool {
        switch self {
        case .system, .pan, .mcp, .qq: return true
        default: return false
        }
    }
}

/// ta 的手。
///
/// 这些工具会被发给模型（function calling），由ta自己决定什么时候用、用什么参数。
/// 每个工具都只做一件小事，而且**只读ta能读的东西**——
/// 日历、提醒这类要用户授权的，授权被拒就老老实实返回「没授权」，绝不假装成功。
///
/// ## 🔴 用户手里的两个闸（2026-09-30）
/// - **总开关** `AppSettings.aiToolsEnabled`：关掉ta只剩聊天。
/// - **分类开关** `AppSettings.disabledToolCategories`：逐类关。
/// 两者都只影响**发给模型的清单**，见 `all()`。
enum DeviceTools {

    // MARK: - 登记

    /// ta全部的手 = App 自带的（**已按「AI 权限」过滤**）+ 外接的。
    ///
    /// **所有链路都走这里**（打字聊天、语音通话、一起听、主动消息、朋友圈），
    /// 所以外接的 MCP 工具接一次就处处可用 —— 包括你直接对ta说话的时候。
    static func all() -> [DeviceTool] {
        grantedBuiltinTools + (isOn(.mcp) ? MCPStore.shared.bridgedTools : [])
    }

    /// 🔴 总开关。关掉之后ta**只能聊天**。
    static var masterEnabled: Bool { AppSettings.shared.aiToolsEnabled }

    /// 某一类现在是不是开着的。
    static func isOn(_ category: ToolCategory) -> Bool {
        AppSettings.shared.isToolOn(category)
    }

    /// App 自带、**并且用户允许**的那些。发给模型的就是这一份。
    static var grantedBuiltinTools: [DeviceTool] {
        guard masterEnabled else { return [] }
        let off = Set(AppSettings.shared.disabledToolCategories)
        return allGroups
            .filter { !off.contains($0.category.rawValue) }
            .flatMap(\.tools)
    }

    /// **全部**内置工具，不管开关。
    ///
    /// ⚠️ 单独留这一份是有原因的：`MCPStore.bridgedTools` 判重时要看**全部**名字 ——
    ///    只看"允许的"那些，同名的 MCP 工具就会被再发一遍（模型收到两份同名函数）。
    /// ⚠️ 也**不能**让判重去调 `all()`：那会绕回来变成无限递归（真会崩栈）。
    static var builtinTools: [DeviceTool] {
        allGroups.flatMap(\.tools)
    }

    /// 内置工具，**按类别分组** —— 「AI 权限」的开关就是在这张表上过滤的。
    ///
    /// ⭐ 集中成一张表的好处：加新工具时只要放进对应的组，开关自动就管得到它。
    ///    （以前这里是一长串 `+` 拼接，`musicTools` 和 `panTools` 还被加了两遍 ——
    ///      模型会收到两份同名函数。改成分组表之后那个重复也一并没了。）
    private static var allGroups: [(category: ToolCategory, tools: [DeviceTool])] {
        [
            (.core, [timeTool, clipboardReadTool, clipboardWriteTool, calculatorTool]),
            (.calendar, [calendarListTool, calendarCreateTool, reminderCreateTool]),
            (.sense, senseTools),
            (.web, webTools),
            (.music, musicTools),
            (.moment, momentTools),
            (.diary, DiaryTools.tools),
            (.pan, panTools),
            (.qq, qqTools + qqBotTools),
            // 系统动作 + `shellTool`（命令行）放一类 ——
            // shell 是这里最狠的一个，它就该跟"能不能替我操作这台手机"捆在一起。
            (.system, systemTools + [shellTool]),
            (.wallet, WalletTools.walletTools),
            (.couple, CoupleTools.coupleTools),
            // ta**主动申请**做的事（打电话 / 看屏幕 / 一起听）。
            // 跟别的不一样的地方：这几个只是"提出来"，真正开始还要用户点头。
            (.companion, CompanionTools.tools)
        ]
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

    /// 工具的中文名（黑匣子/工具条上显示用）。
    ///
    /// ⚠️ 查的是**全部**内置工具，不是"允许的"那一份 ——
    ///    不然用户后来关掉某一类，历史记录里那些调用就变成一串英文 id 了。
    static func title(for name: String) -> String {
        if let hit = builtinTools.first(where: { $0.name == name }) { return hit.title }
        if let hit = MCPStore.shared.bridgedTools.first(where: { $0.name == name }) { return hit.title }
        return name
    }

    static func run(name: String, arguments: [String: Any]) async -> String {
        // ⚠️ 「工具不存在」和「工具被关掉了」必须**分开说**：
        //    前一种模型会去猜别的工具，后一种它才会老实告诉用户"这个没开"。
        //    混成一句话的后果，是用户看着ta去用另一个工具绕过去。
        if let blocked = blockedTool(named: name) {
            return "「\(blocked.title)」这个能力被用户关掉了（设置 → AI 权限）。"
                + "照实跟他说这个没开，别自己想办法绕过。"
        }
        guard let tool = all().first(where: { $0.name == name }) else {
            return "没有叫「\(name)」的工具。"
        }
        // ⭐ 全工具埋点：内置工具 + 外接 MCP **全都走这个入口**，埋这一处即全覆盖。
        //    在**执行前**记一笔；摘要已脱敏 —— 字符串只记 key=长度、标量记值，
        //    绝不带聊天/人设/剪贴板/日历标题这些原文。
        BlackBox.tool(name, summarize(arguments))
        return await tool.run(arguments)
    }

    /// 内置清单里有、但**用户不让用**的那个工具。
    ///
    /// 拿它把"不存在"和"被关掉"分开 —— 见 `run(name:arguments:)` 上面那段。
    private static func blockedTool(named name: String) -> DeviceTool? {
        guard let tool = builtinTools.first(where: { $0.name == name }) else { return nil }
        guard masterEnabled else { return tool }
        return grantedBuiltinTools.contains(where: { $0.name == name }) ? nil : tool
    }

    /// 被用户关掉的能力的中文名 —— **给ta的提示词用**。
    ///
    /// ⚠️ 为什么非要有这个：关掉之后工具**根本不发给ta**，于是ta**不知道自己不能做**，
    ///    用户一句「放首歌」ta就顺口「好呀，正在放～」—— 那就是"假装完成"，
    ///    用户最不能接受的一种。所以关掉的能力必须**明写进系统提示**。
    ///
    /// 总开关关掉时返回空 —— 那种情况由提示词那边单独说一句更完整的（列 13 条太长）。
    static var disabledCategoryLabels: [String] {
        guard masterEnabled else { return [] }
        let off = Set(AppSettings.shared.disabledToolCategories)
        return ToolCategory.allCases.filter { off.contains($0.rawValue) }.map(\.label)
    }

    /// 脱敏入参摘要：字符串只记 `key=长度`，标量记值，其它记 `key=?`。
    /// 按 key 排序，同一调用算出同一串 —— 日志里好比对，也绝不会泄原文。
    private static func summarize(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "" }
        let parts = arguments.keys.sorted().map { key -> String in
            let value = arguments[key]
            if let text = value as? String { return "\(key)=\(text.count)" }
            if let flag = value as? Bool { return "\(key)=\(flag)" }
            if let number = value as? NSNumber { return "\(key)=\(number)" }
            return "\(key)=?"
        }
        return parts.joined(separator: " ")
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
