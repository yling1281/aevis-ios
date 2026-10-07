import Foundation

enum LLMError: LocalizedError {
    case notConfigured
    case badURL
    case emptyReply
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没填 API Key。打开右上角设置 →「模型接入」填上再试。"
        case .badURL:
            return "接口地址不对，检查一下 Base URL。"
        case .emptyReply:
            return "\(Pronoun.current)这次没说话，再试一次。"
        case let .http(status, body):
            switch status {
            case 401, 403:
                return "Key 被拒绝了（\(status)）。检查 API Key 是否正确。"
            case 404:
                return "接口地址找不到（404）。Base URL 末尾不要再带 /chat/completions。"
            case 429:
                return "请求太频繁或额度用完了（429）。"
            default:
                return "接口返回 \(status)：\(body.prefix(180))"
            }
        }
    }
}

/// 只做一件事：把对话流式发给一个 OpenAI 兼容接口，逐字吐回来。
///
/// 现在多了一层：**工具调用**。ta会自己决定要不要用手 ——
/// 比如用户问「今天几号」，ta先调 get_current_time，拿到结果再用自己的话说出来。
enum LLMService {

    /// 「这一轮对话是说给**哪个会话**听的」—— 群聊成员调工具时要靠它把气泡落回**群**那份，
    /// 而不是落进用户此刻正在看的那个会话。
    ///
    /// ## 为什么必须是 `@TaskLocal`
    /// 工具的实际执行点是**本文件 `streamReply` 里的 `Task.detached`**（见下面 :60 附近，以及
    /// `WalletTools` 里那句「工具是在 `Task.detached` 上跑的」注释）。`DeviceTool.run` 的闭包
    /// 签名是 `([String: Any]) async -> String`，**没有地方**能塞一个 owner 进去 ——
    /// 硬要在签名链上显式传，等于要改 `DeviceTools` + 十几个工具定义文件，这是大改。
    ///
    /// ⚠️ `@TaskLocal` **不会**从调用方**传播进**一个 `Task.detached`（detached 不继承调用方的
    ///    task-local）。所以**绝对不能**指望「在调用方设好、detached 里自然读到」。
    ///    正确用法是：owner 作为**形参**跨进 `streamReply`，在**detached 任务体内部**
    ///    （`$conversationOwner.withValue(owner) { ... }`）绑定，再向下包住 `runConversation`
    ///    整段（含工具执行）。这样绑定与读取在**同一个任务**里，工具闭包读到的就是它。
    ///
    /// ## 一对一零回归
    /// 一对一路径不传 `owner`（默认 `nil`）⇒ 读出来是 `nil` ⇒ 三个写点全部退回
    /// 「落当前会话」的老行为，与改动前**逐字一致**。只有群聊显式传群 id。
    @TaskLocal
    static var conversationOwner: UUID? = nil

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: [String: Any]
    }

    private struct RoundResult {
        var text: String
        var toolCalls: [ToolCall]
        var assistantMessage: [String: Any]
    }

    static func streamReply(
        config: LLMConfig,
        systemPrompt: String,
        history: [ChatMessage],
        memory: [String] = [],
        tools: [DeviceTool] = [],
        owner: UUID? = nil,
        onToolActivity: (@Sendable (String) -> Void)? = nil,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    // ⭐ 在 **detached 任务体内部**绑定 owner —— 这样 `runConversation`
                    //    整段（含工具执行）都在它的动态作用域里，工具闭包读
                    //    `LLMService.conversationOwner` 就能拿到。**不能**在调用方设好后指望它传播进来
                    //    （`Task.detached` 不继承调用方的 task-local，见 `conversationOwner` 的注释）。
                    try await $conversationOwner.withValue(owner) {
                        try await runConversation(
                            config: config,
                            systemPrompt: systemPrompt,
                            history: history,
                            memory: memory,
                            tools: tools,
                            onDelta: { piece in
                                _ = continuation.yield(piece)
                            },
                            onTool: onToolActivity,
                            onReasoning: onReasoningDelta
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 设置页的「测试连接」用：只跑一次、只取一小段。
    static func probe(config: LLMConfig) async throws -> String {
        var collected = ""
        let history = [ChatMessage(role: .user, text: "用不超过六个字回我一句问候。")]
        for try await piece in streamReply(
            config: config,
            systemPrompt: "你在做一次接口连通性测试，只回一句简短的问候。",
            history: history
        ) {
            collected += piece
            if collected.count >= 40 { break }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMError.emptyReply }
        return trimmed
    }

    /// 让ta知道"现在"是什么时候。
    /// 单独一条 system 消息，不混进人设提示词 —— 人设是用户写的，不该被我改。
    private static func timeContext() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日"
        let day = dateFormatter.string(from: Date())

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.dateFormat = "EEEE"
        let weekday = weekdayFormatter.string(from: Date())

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: Date())

        let timezone = TimeZone.current
        // 整数化：+8.0 显示成 +8，口语一些。
        let offset = Int(Double(timezone.secondsFromGMT()) / 3600)
        let sign = offset >= 0 ? "+" : ""

        return "今天是 \(day)，\(weekday)；现在时刻是 \(time)（\(timezone.identifier)，UTC\(sign)\(offset)）。"
            + "你知道今天几号、现在几点，直接用这个回答就行，不用去查。"
    }

    // MARK: - 多轮：ta可以用几次手再说

    /// 一轮对话最多让ta用几轮工具。
    ///
    /// ⚠️ 2026-10-05：从 4 提到 **8** —— 用户要的是「能连着干」，
    ///    4 轮常常不够（搜一下、翻一页、再查一次就没了）。
    ///    另有 `conversationBudget` 兜底，避免ta陷在循环里出不来。
    private static let maxRounds = 8

    /// 一整轮对话（含所有工具往返）的总时限（秒）。
    ///
    /// ⚠️ 纯时间戳比较、**不用 `Task.sleep`**（那会阻塞、还多占一个任务）。
    private static let conversationBudget: TimeInterval = 120

    private static func runConversation(
        config: LLMConfig,
        systemPrompt: String,
        history: [ChatMessage],
        memory: [String],
        tools: [DeviceTool],
        onDelta: @escaping (String) -> Void,
        onTool: (@Sendable (String) -> Void)?,
        onReasoning: ((String) -> Void)?
    ) async throws {
        // 让ta「感知现实时间」：把当前时间直接写进系统提示词，
        // 不用ta每次都去调 get_current_time。
        //
        // 🔴 消息要能**重建** —— 降级之后得把那段「你能做的事」拿掉，
        //    否则提示词还在说"你能发朋友圈"，而工具已经被清空了（= 教ta说谎）。
        //    所以整段抽成这个局部函数，降级时用 `includeCapability: false` 重建。
        //
        // ⭐ 「你能做的事」能力规格 —— 紧跟人设、排在时间之前。
        //
        // 🔴 为什么就在这里注入：这是所有模型调用的**唯一漏斗**
        //    （打字聊天 / 通话 / 一起听 / QQ / 配对桥全都走 `runConversation`），
        //    注入一次处处带上，不会漏；也正是用户说的「给 AI 供应商 API 时
        //    顺便把规格包含进去」。⚠️ 因此 `Persona.swift` 里**不再写第二份**
        //    （写两遍会重复注入）。总开关关掉时 `block()` 返回 nil，这里自然跳过。
        func buildMessages(includeCapability: Bool) -> [[String: Any]] {
            // systemPrompt 永远第 0 条。
            var built: [[String: Any]] = [
                ["role": "system", "content": systemPrompt]
            ]
            // 能力规格只在允许时注入（工具被卸掉后就不该再告诉ta"你能做这些"）。
            if includeCapability, let capability = CapabilitySpec.block() {
                built.append(["role": "system", "content": capability])
            }
            built.append(["role": "system", "content": Self.timeContext()])
            // 长期记忆、屏幕使用时间这类「背景资料」都走这一条 ——
            // 和人设、时间一样单独成段，不混写在一起，
            // 这样哪一段出问题都能单独关掉、单独查。
            if !memory.isEmpty {
                let block = """
                这些是你知道的背景（自然地用，别像念资料一样背出来）：
                \(memory.joined(separator: "\n"))
                """
                built.append(["role": "system", "content": block])
            }
            // 带多少条历史由用户决定：太多又慢又贵，太少ta会失忆
            let limit = max(6, min(config.contextLimit, 200))
            // ⚠️⚠️ **别再只砍尾巴**（2026-10-06 改）。
            //
            // 原来是 `history.suffix(limit)`：超了就把**最老的那批整段扔掉**。
            // 而「她是谁、你们怎么认识的、说好过什么」恰恰在最前面 ——
            // 越聊越远，那些就最先被丢，表现就是用户说的「她容易失忆」。
            //
            // 新口径：**开头留一小段 + 最近留一大段**，只丢中间太远的。
            // 开头留多少：`limit` 的 1/3、最多 6 条；`limit < 12` 时不留
            // （小窗口被开头占掉一半反而更糟）。被丢掉的中间那段由
            // 长期记忆 / 记忆网兜着。
            let openingKeep = limit >= 12 ? min(6, limit / 3) : 0
            var picked: [ChatMessage]
            var skippedMiddle = false
            if history.count <= limit {
                picked = history
            } else {
                picked = Array(history.prefix(openingKeep))
                    + Array(history.suffix(limit - openingKeep))
                skippedMiddle = openingKeep > 0
            }
            for (offset, item) in picked.enumerated() {
                // 开头那几条发完、中间那段被跳过 —— 明说一句，
                // 免得她以为"刚才那件事压根没发生过"。
                if skippedMiddle, offset == openingKeep {
                    built.append([
                        "role": "system",
                        "content": "（中间隔了一段比较早的闲聊，这里先略过了。）"
                    ])
                }
                guard !item.text.isEmpty else { continue }
                // ⭐ 群聊：给**别人的话**（非 user 的历史）加上「名字：」前缀。
                //
                // 🔴 为什么必须有这一段：这条漏斗把所有非 user 的历史都塞成
                //    `assistant` 角色 —— 一对一没毛病，但**群里两个 AI 会因此把
                //    对方说过的话认成「我自己刚说的」**，于是复读、串味、人格互染。
                //    前缀就是那条唯一能告诉它「这句是谁说的」的线。
                //
                // 名字取 `speakerName`（落库时存的快照）—— **不在这里读 `PersonaStore`**：
                //    这段跑在后台任务里，主线程隔离的 Store 在后台读会在 iOS 26 上崩。
                // 一对一消息 `speakerName` 是 nil，不前缀，行为跟以前完全一样。
                let speaker = (item.speakerName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let content: String
                if item.role != .user, !speaker.isEmpty {
                    content = "\(speaker)：\(item.text)"
                } else {
                    content = item.text
                }
                built.append([
                    "role": item.role == .user ? "user" : "assistant",
                    "content": content
                ])
            }
            return built
        }

        // 循环里会往数组里 append（assistant / tool 消息），所以要 `var`；
        // 而降级只发生在 round == 0、还没 append 过任何东西之前，重建是安全的。
        //
        // ⚠️ `includeCapability` 这里要多问一句 `remembersNoTools`（2026-10-07 补）：
        //    这家接口**已经被证明不认 tools** 时，`sendOnce` 会直接不发工具 ——
        //    而此时提示词里若还留着「你能做的事」清单，就是在**教 ta 承诺它做不到的事**
        //    （项目红线之一：不许"假装完成"）。
        //    第一次（还没记住）照常乐观地带上；真被卸掉后这一步会把它撤下来。
        //    ✅ 但这个记忆**现在有 6 小时 TTL**（`interfaceMemoryTTL`），不会再永久粘住 ——
        //       过期后 `remembersNoTools` 自动翻回 false，ta 下一步就重新试（且老格式 key 见即删）。
        var messages = buildMessages(
            includeCapability: !remembersNoTools(baseURL: config.baseURL, model: config.model)
        )

        // ⚠️ 纯时间戳比较（`Date()` 差值），**不用 Task.sleep** —— 后者会阻塞，
        //    而且ta正流式吐字的时候，任何 await 停顿都会让界面看起来卡住。
        let deadline = Date().addingTimeInterval(conversationBudget)
        var usedTools = false

        for round in 0..<maxRounds {
            // 总时限到了就跳出去走「强制收尾」—— 不再让ta调工具，直接用自己话回。
            if Date() >= deadline {
                onTool?("想得有点久了，先停下来")
                break
            }

            var result: RoundResult
            do {
                result = try await sendOnce(
                    config: config,
                    messages: messages,
                    tools: tools,
                    onDelta: onDelta,
                    onReasoning: onReasoning
                )
            } catch LLMError.http(let status, let body) where status == 400
                && ((!tools.isEmpty) || config.reasoning != .off) && round == 0 {
                // 400 不一定是「既不认 tools 又不认 reasoning」—— 老代码一上来就把
                // 两样**一起**卸掉，结果「接口不认一个推理参数」也把**全部工具能力连坐清空**，
                // ta 这一轮手里一件工具都没有。改成逐级卸载、**每一级只卸一样**。
                result = try await degrade(
                    config: config,
                    messages: messages,
                    tools: tools,
                    onDelta: onDelta,
                    onReasoning: onReasoning,
                    onTool: onTool,
                    firstBody: body,
                    rebuildMessages: buildMessages
                )
            }

            if result.toolCalls.isEmpty {
                return
            }

            usedTools = true
            messages.append(result.assistantMessage)

            for call in result.toolCalls {
                onTool?(DeviceTools.title(for: call.name))
                let output = await DeviceTools.run(name: call.name, arguments: call.arguments)
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": output
                ])
            }
        }

        // 走到这儿 = **轮数用完（或超时），而ta还惦记着调工具**。
        // 补那句话逼ta收尾，并**真的再问一次**（这一次不带工具）——
        // 少问这一次的话，ta最后一轮只调了工具、没有正文，用户就干等一个空回复。
        if usedTools {
            messages.append([
                "role": "user",
                "content": "（工具已经用完了，现在直接用你自己的话回我，别再调工具。）"
            ])
            _ = try await sendOnce(
                config: config,
                messages: messages,
                tools: [],
                onDelta: onDelta,
                onReasoning: onReasoning
            )
        }
    }

    // MARK: - 400 降级：逐级卸载参数

    /// 400 之后逐级卸载参数，**每一级只卸一样** ——
    /// 🔴 顺序不能反：先卸 `reasoning_effort`（工具保住），
    ///    只有连工具也不认时才卸工具。老代码一次卸两样，
    ///    结果「接口不认一个推理参数」就把全部工具能力连坐清空了。
    ///
    /// - Parameters:
    ///   - firstBody: 第一次 400 的响应体原文（会被摘成一行带进提示语和黑匣子）。
    ///   - rebuildMessages: 重建消息。第 3 步（卸工具）时**必须**传 `includeCapability: false` ——
    ///     工具都卸了，提示词里那段「你能做的事」就不能再留，否则等于教ta说谎。
    /// - Returns: 某一级降级成功后真正拿到的结果。
    /// - Throws: 三级都失败时抛**最后一次**的错误；**绝不吞错**（吞了上层会以为成功）。
    private static func degrade(
        config: LLMConfig,
        messages: [[String: Any]],
        tools: [DeviceTool],
        onDelta: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)?,
        onTool: (@Sendable (String) -> Void)?,
        firstBody: String,
        rebuildMessages: (Bool) -> [[String: Any]]
    ) async throws -> RoundResult {
        // 一个可卸的东西都没有（catch 的 where 已挡住这种情况，这里只是兜底）：
        // 直接把第一次的错误抛上去，**别重试**。
        if config.reasoning == .off && tools.isEmpty {
            throw LLMError.http(status: 400, body: firstBody)
        }

        // ── 第 2 步：只卸推理参数，工具**原样保住** ──
        // ⚠️ 这是本次修复的核心 —— 老代码在这一步就把 tools 一起清空成 [] 了。
        var noThink = config
        noThink.reasoning = .off
        var lastBody = firstBody

        if config.reasoning != .off {
            do {
                let result = try await sendOnce(
                    config: noThink,
                    messages: messages,
                    tools: tools,
                    onDelta: onDelta,
                    onReasoning: onReasoning
                )
                // ⭐ 只有**确实因为推理参数**才降级成功时才记 —— 失败说明不是它的问题，
                //    记了就冤枉了这家接口（老代码是无条件记的）。
                rememberNoReasoning(baseURL: config.baseURL, model: config.model)
                onTool?("接口不认推理参数（400）：\(brief(firstBody)) —— 已关掉它继续回答，工具照常可用")
                BlackBox.log("❗️接口不认 reasoning_effort，已关掉它重试并成功；工具仍然可用。接口原话：\(brief(firstBody))")
                return result
            } catch LLMError.http(let status, let body) where status == 400 {
                // 推理参数不是病根，记下第二个 body，继续往下卸工具。
                lastBody = body
            }
            // ⚠️ 别的错误类型**不捕获**，自动往上抛 —— 绝不能吞。
        }

        // ── 第 3 步：连工具也不认，卸掉工具、纯聊天 ──
        if !tools.isEmpty {
            // 🔴 必须用 includeCapability: false 重建 —— 工具没了，就不能再告诉ta「你能做这些」。
            let result = try await sendOnce(
                config: noThink,
                messages: rebuildMessages(false),
                tools: [],
                onDelta: onDelta,
                onReasoning: onReasoning
            )
            rememberNoTools(baseURL: config.baseURL, model: config.model)
            onTool?("接口连工具都不认（400）：\(brief(lastBody)) —— 这次只能纯聊天")
            BlackBox.log("❗️接口不认 tools，已卸掉全部工具改为纯聊天并成功。接口原话：\(brief(lastBody))")
            return result
        }
        // ⚠️ 第 3 步里的 `sendOnce` 抛错时**不捕获**，原样往上抛（含又是 400 的情况）——
        //    绝不无限重试、绝不吞错。

        // 走到这儿 = 没工具可卸、或卸推理参数后仍然 400。
        // 抛出最后拿到的那个错误，让上层如实报给用户。
        throw LLMError.http(status: 400, body: lastBody)
    }

    /// 把接口响应体压成**一行短摘要**，给用户提示语和黑匣子共用。
    /// 去换行、把连续空白压成一个空格、截到 160 字符（超了加省略号）。
    /// ⚠️ 只做截断、不做别的加工 —— 响应体是接口返回的，正常不含 API Key。
    private static func brief(_ body: String) -> String {
        let flattened = body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return "（接口没给原因）" }
        return flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened
    }

    /// 把 App 的四档翻译成**这家接口真正认的** `reasoning_effort` 取值。
    /// 返回 `nil` = 这一档干脆别发这个字段。
    ///
    /// 🔴 为什么必须有这一层（2026-10-07 真踩到）：
    ///   DeepSeek V4 的 `reasoning_effort` **只认 `high` / `max`** ——
    ///   官方公告原文（api-docs.deepseek.com/zh-cn/news/news260424）：
    ///   「思考模式支持 reasoning_effort 参数设置思考强度(high/max)」。
    ///   而 `ReasoningBudget` 的 rawValue 是 `low` / `medium` / `high`，
    ///   于是 `.low` / `.medium` 会被接口 400 打回。虽然 `degrade` 兜得住，
    ///   但那要白跑一次 400、还多一次往返，用户还会看到一次没必要的降级提示 ——
    ///   **从源头翻译对更便宜**。
    private static func effortValue(_ budget: ReasoningBudget, baseURL: String) -> String? {
        guard budget != .off else { return nil }
        // DeepSeek（官方域名，以及走它中转的地址）只认 high / max。
        if baseURL.lowercased().contains("deepseek") {
            // `.low` / `.medium` 在 DeepSeek 上没有对应档，取最接近的 `high`；
            // `.high` 的语义是"想得最久、适合复杂问题"，对应它的最高档 `max`。
            return budget == .high ? "max" : "high"
        }
        // 其余（OpenAI 系等）沿用原值 low / medium / high。
        return budget.rawValue
    }

    // MARK: - 单轮

    private static func sendOnce(
        config: LLMConfig,
        messages: [[String: Any]],
        tools: [DeviceTool],
        onDelta: @escaping (String) -> Void,
        onReasoning: ((String) -> Void)?
    ) async throws -> RoundResult {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LLMError.notConfigured }

        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw LLMError.badURL }
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") {
            base += "/chat/completions"
        }
        guard let url = URL(string: base) else { throw LLMError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": messages
        ]
        // 「这家接口已经证明不认 tools」时**直接不发**，省掉每次那一次必然 400 的往返。
        // ⚠️ 此时调用方 `runConversation` 仍以为工具可用（会走 `result.toolCalls.isEmpty`
        //    直接返回，行为没问题），只是这一轮 ta 没有手 —— 这是已知、可接受的降级
        //    （总比每次多跑一次 400 强）。
        if !tools.isEmpty && !remembersNoTools(baseURL: config.baseURL, model: config.model) {
            body["tools"] = DeviceTools.definitions()
            body["tool_choice"] = "auto"
        }
        // 推理预算：关闭时不传这个字段（有些模型不认，传了反而报错）。
        // ⚠️ 取值要**按供应商翻译**（`effortValue`）—— DeepSeek V4 只认 `high`/`max`，
        //    直接发 `low`/`medium` 会被 400 打回（虽然 `degrade` 兜得住，但白跑一次往返）。
        // ⚠️ 这家接口**已经证明不认** `reasoning_effort`（记在 UserDefaults，
        //    key 里带 baseURL+model 的稳定哈希）时就不传了 —— 直接省掉每次那一次 400 往返。
        //    换模型 / 换地址 → hash 变 → 自然重新试。
        if let effort = effortValue(config.reasoning, baseURL: config.baseURL),
           !remembersNoReasoning(baseURL: config.baseURL, model: config.model) {
            body["reasoning_effort"] = effort
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.badURL }

        guard (200..<300).contains(http.statusCode) else {
            var collected = ""
            for try await line in bytes.lines {
                collected += line
                if collected.count > 800 { break }
            }
            throw LLMError.http(status: http.statusCode, body: collected)
        }

        var text = ""
        // 工具调用的参数是分片流式过来的，得按 index 拼接
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else {
                continue
            }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                onDelta(piece)
            }

            // ⭐ 深度思考：把 `reasoning_content` 透出去。
            // ⚠️ 有的兼容实现字段名叫 `reasoning` —— **两个都试**：
            //    先看 `reasoning_content`，没有再退到 `reasoning`，且**只有它是 String 才算**。
            // 🔴 这段**绝不混进 `content`**，也不混进最终回复 —— 否则用户会看到ta的内心独白。
            //    这里传出去的是**增量**（一段一段），全量由调用方自己拼。
            if let piece = (delta["reasoning_content"] as? String)
                ?? (delta["reasoning"] as? String), !piece.isEmpty {
                onReasoning?(piece)
            }

            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                for fragment in fragments {
                    let index = (fragment["index"] as? Int) ?? 0
                    var entry = calls[index] ?? (id: "", name: "", arguments: "")
                    if let id = fragment["id"] as? String, !id.isEmpty {
                        entry.id = id
                    }
                    if let function = fragment["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty {
                            entry.name = name
                        }
                        if let arguments = function["arguments"] as? String {
                            entry.arguments += arguments
                        }
                    }
                    calls[index] = entry
                }
            }
        }

        let toolCalls: [ToolCall] = calls
            .sorted { $0.key < $1.key }
            .compactMap { _, entry in
                guard !entry.name.isEmpty else { return nil }
                let parsed = (try? JSONSerialization.jsonObject(
                    with: Data(entry.arguments.utf8)
                ) as? [String: Any]) ?? [:]
                return ToolCall(
                    id: entry.id.isEmpty ? "call_\(entry.name)" : entry.id,
                    name: entry.name,
                    arguments: parsed
                )
            }

        var assistant: [String: Any] = ["role": "assistant"]
        if toolCalls.isEmpty {
            assistant["content"] = text
        } else {
            assistant["content"] = text.isEmpty ? NSNull() : text
            assistant["tool_calls"] = calls
                .sorted { $0.key < $1.key }
                .compactMap { _, entry -> [String: Any]? in
                    guard !entry.name.isEmpty else { return nil }
                    return [
                        "id": entry.id.isEmpty ? "call_\(entry.name)" : entry.id,
                        "type": "function",
                        "function": ["name": entry.name, "arguments": entry.arguments]
                    ]
                }
        }

        return RoundResult(text: text, toolCalls: toolCalls, assistantMessage: assistant)
    }

    // MARK: - 「这家接口不认推理参数」的记忆

    /// 这类「这家接口不认 X」的记忆**只留 6 小时**。
    /// 为什么要有到期：以前是永久的 —— 一次偶发 400（某个工具的 schema 被中转商挑刺、
    /// 或接口临时抽风）就把 ta 的工具**永久**废掉，用户还没法自救（界面上没有开关）。
    /// 6 小时的含义：一次会话内不会反复白跑 400 往返，但第二天一定重新试。
    private static let interfaceMemoryTTL: TimeInterval = 6 * 3600

    /// 把 `baseURL|model` 算成 **8 位大写 hex**（FNV-1a 稳定哈希）。
    /// ⚠️ 绝不能用 `String.hashValue` —— 后者每次进程启动都会变（Swift 的哈希是随机加盐的），
    ///    存进去的 key 下次启动就对不上了，等于没记。
    /// 两个 key 函数（tools / reasoning）**共用这一份**，别再各抄一遍（以前是重复的两段循环）。
    private static func hashHex(baseURL: String, model: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in (baseURL + "|" + model).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%08X", UInt32(truncatingIfNeeded: hash))
    }

    /// 记过的判定，落在 UserDefaults。key 里带 baseURL+model 的稳定哈希 ——
    /// 所以**换模型 / 换地址会自然得到一个新 key**，等于重新试一次，
    /// 不会被上一家接口的"坏印象"连累。
    ///
    /// ⚠️ 用**自己算的稳定哈希**（FNV-1a），**绝不能用 `String.hashValue`** ——
    ///    后者每次进程启动都会变（Swift 的哈希是随机加盐的），
    ///    存进去的 key 下次启动就对不上了，等于没记。
    private static func noReasoningUntilKey(baseURL: String, model: String) -> String {
        "aevis.noReasoningUntil.\(hashHex(baseURL: baseURL, model: model))"
    }

    /// 这家接口是不是**还在**「不认 `reasoning_effort`」的记忆有效期内。
    private static func remembersNoReasoning(baseURL: String, model: String) -> Bool {
        // 老格式（`aevis.noReasoning.<hex>` = Bool true，永不过期）一律作废：
        // 见到就删 —— 老用户升级后**立刻**恢复手感，不用等 TTL 走完。
        let legacyKey = "aevis.noReasoning." + hashHex(baseURL: baseURL, model: model)
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        let until = UserDefaults.standard.double(
            forKey: noReasoningUntilKey(baseURL: baseURL, model: model)
        )
        return until > Date().timeIntervalSince1970
    }

    /// 记下「这家接口不认 `reasoning_effort`」—— 从此刻起 `interfaceMemoryTTL` 内不再带它。
    private static func rememberNoReasoning(baseURL: String, model: String) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 + interfaceMemoryTTL,
            forKey: noReasoningUntilKey(baseURL: baseURL, model: model)
        )
    }

    // MARK: - 「这家接口不认工具」的记忆

    /// 和 `noReasoningUntilKey` 同一套写法（FNV-1a 稳定哈希，绝不用 `String.hashValue`），
    /// 只是前缀换成 `aevis.noToolsUntil.` —— 换模型 / 换地址会自然得到新 key，重新试一次。
    private static func noToolsUntilKey(baseURL: String, model: String) -> String {
        "aevis.noToolsUntil.\(hashHex(baseURL: baseURL, model: model))"
    }

    /// 这家接口是不是**还在**「不认 `tools`」的记忆有效期内。
    private static func remembersNoTools(baseURL: String, model: String) -> Bool {
        // 老格式（`aevis.noTools.<hex>` = Bool true，永不过期）一律作废：
        // 见到就删 —— 老用户升级后**立刻**恢复手感，不用等 TTL 走完。
        let legacyKey = "aevis.noTools." + hashHex(baseURL: baseURL, model: model)
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        let until = UserDefaults.standard.double(
            forKey: noToolsUntilKey(baseURL: baseURL, model: model)
        )
        return until > Date().timeIntervalSince1970
    }

    /// 记下「这家接口不认 `tools`」—— 从此刻起 `interfaceMemoryTTL` 内不再带工具定义。
    private static func rememberNoTools(baseURL: String, model: String) {
        UserDefaults.standard.set(
            Date().timeIntervalSince1970 + interfaceMemoryTTL,
            forKey: noToolsUntilKey(baseURL: baseURL, model: model)
        )
    }
}
