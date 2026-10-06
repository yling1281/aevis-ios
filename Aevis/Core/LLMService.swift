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
        onToolActivity: (@Sendable (String) -> Void)? = nil,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
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
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        // ⭐ 「你能做的事」能力规格 —— 紧跟人设、排在时间之前。
        //
        // 🔴 为什么就在这里注入：这是所有模型调用的**唯一漏斗**
        //    （打字聊天 / 通话 / 一起听 / QQ / 配对桥全都走 `runConversation`），
        //    注入一次处处带上，不会漏；也正是用户说的「给 AI 供应商 API 时
        //    顺便把规格包含进去」。⚠️ 因此 `Persona.swift` 里**不再写第二份**
        //    （写两遍会重复注入）。总开关关掉时 `block()` 返回 nil，这里自然跳过。
        if let capability = CapabilitySpec.block() {
            messages.append(["role": "system", "content": capability])
        }
        messages.append(["role": "system", "content": Self.timeContext()])
        // 长期记忆、屏幕使用时间这类「背景资料」都走这一条 ——
        // 和人设、时间一样单独成段，不混写在一起，
        // 这样哪一段出问题都能单独关掉、单独查。
        if !memory.isEmpty {
            let block = """
            这些是你知道的背景（自然地用，别像念资料一样背出来）：
            \(memory.joined(separator: "\n"))
            """
            messages.append(["role": "system", "content": block])
        }
        // 带多少条历史由用户决定：太多又慢又贵，太少ta会失忆
        let limit = max(6, min(config.contextLimit, 200))
        for item in history.suffix(limit) {
            guard !item.text.isEmpty else { continue }
            messages.append([
                "role": item.role == .user ? "user" : "assistant",
                "content": item.text
            ])
        }

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
            } catch LLMError.http(let status, _) where status == 400
                && ((!tools.isEmpty) || config.reasoning != .off) && round == 0 {
                // 有些接口既不认 tools、也不认 reasoning_effort。
                // 那就退回最保守的请求再试一次 —— 报错总比"ta突然不说话了"强。
                onTool?("这个接口不认工具或推理参数，这次用最保守的方式回答")
                // ⚠️ 这次**没有工具可用**了（下面 tools 被清空成 []）——
                //    记进黑匣子，让「ta这轮其实不能动手」这件事可见，
                //    而不是用户事后发现「联网搜索有跟没有一样」却查无现场。
                BlackBox.log("❗️接口不兼容 tools / reasoning，本次已降级为纯聊天")
                var plain = config
                plain.reasoning = .off
                result = try await sendOnce(
                    config: plain,
                    messages: messages,
                    tools: [],
                    onDelta: onDelta,
                    onReasoning: onReasoning
                )
                // ⭐ 记住「这家 baseURL + model 不认 reasoning_effort」，
                //    后续请求直接不带这个字段 —— 免得每次回答都白跑一次 400 往返。
                //    ⚠️ 只在**确实因为推理参数**才降级时记（tools 一起被砍那不算）。
                //    换模型 / 换地址时 hash 变了，会自然重新试 —— 见 `noReasoningKey`。
                if config.reasoning != .off {
                    rememberNoReasoning(baseURL: config.baseURL, model: config.model)
                }
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
        if !tools.isEmpty {
            body["tools"] = DeviceTools.definitions()
            body["tool_choice"] = "auto"
        }
        // 推理预算：关闭时不传这个字段（有些模型不认，传了反而报错）。
        // ⚠️ 这家接口**已经证明不认** `reasoning_effort`（记在 UserDefaults，
        //    key 里带 baseURL+model 的稳定哈希）时就不传了 —— 直接省掉每次那一次 400 往返。
        //    换模型 / 换地址 → hash 变 → 自然重新试。
        if let effort = config.reasoning.parameter,
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

    /// 记过的判定，落在 UserDefaults。key 里带 baseURL+model 的稳定哈希 ——
    /// 所以**换模型 / 换地址会自然得到一个新 key**，等于重新试一次，
    /// 不会被上一家接口的"坏印象"连累。
    ///
    /// ⚠️ 用**自己算的稳定哈希**（FNV-1a），**绝不能用 `String.hashValue`** ——
    ///    后者每次进程启动都会变（Swift 的哈希是随机加盐的），
    ///    存进去的 key 下次启动就对不上了，等于没记。
    private static func noReasoningKey(baseURL: String, model: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in (baseURL + "|" + model).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(format: "%08X", UInt32(truncatingIfNeeded: hash))
        return "aevis.noReasoning.\(hex)"
    }

    /// 这家接口是不是已经证明不认 `reasoning_effort`。
    private static func remembersNoReasoning(baseURL: String, model: String) -> Bool {
        UserDefaults.standard.bool(forKey: noReasoningKey(baseURL: baseURL, model: model))
    }

    /// 记下「这家接口不认 `reasoning_effort`」—— 后续请求直接不带。
    private static func rememberNoReasoning(baseURL: String, model: String) {
        UserDefaults.standard.set(true, forKey: noReasoningKey(baseURL: baseURL, model: model))
    }
}
