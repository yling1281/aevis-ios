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
/// 现在多了一层：**工具调用**。她会自己决定要不要用手 ——
/// 比如用户问「今天几号」，她先调 get_current_time，拿到结果再用自己的话说出来。
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
        onToolActivity: (@Sendable (String) -> Void)? = nil
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
                        onTool: onToolActivity
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

    /// 让她知道"现在"是什么时候。
    /// 单独一条 system 消息，不混进人设提示词 —— 人设是用户写的，不该被我改。
    private static func timeContext() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        let now = formatter.string(from: Date())

        let timezone = TimeZone.current
        let offset = Double(timezone.secondsFromGMT()) / 3600
        let sign = offset >= 0 ? "+" : ""

        return "现在是 \(now)（\(timezone.identifier)，UTC\(sign)\(offset)）。"
            + "你知道今天几号、现在几点，直接用这个回答就行，不用去查。"
    }

    // MARK: - 多轮：她可以用几次手再说

    private static func runConversation(
        config: LLMConfig,
        systemPrompt: String,
        history: [ChatMessage],
        memory: [String],
        tools: [DeviceTool],
        onDelta: @escaping (String) -> Void,
        onTool: (@Sendable (String) -> Void)?
    ) async throws {
        // 让她「感知现实时间」：把当前时间直接写进系统提示词，
        // 不用她每次都去调 get_current_time。
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "system", "content": Self.timeContext()]
        ]
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
        // 带多少条历史由用户决定：太多又慢又贵，太少她会失忆
        let limit = max(6, min(config.contextLimit, 200))
        for item in history.suffix(limit) {
            guard !item.text.isEmpty else { continue }
            messages.append([
                "role": item.role == .user ? "user" : "assistant",
                "content": item.text
            ])
        }

        let maxRounds = 4
        var usedTools = false

        for round in 0..<maxRounds {
            var result: RoundResult
            do {
                result = try await sendOnce(
                    config: config,
                    messages: messages,
                    tools: tools,
                    onDelta: onDelta
                )
            } catch LLMError.http(let status, _) where status == 400
                && ((!tools.isEmpty) || config.reasoning != .off) && round == 0 {
                // 有些接口既不认 tools、也不认 reasoning_effort。
                // 那就退回最保守的请求再试一次 —— 报错总比"她突然不说话了"强。
                onTool?("这个接口不认工具或推理参数，这次用最保守的方式回答")
                var plain = config
                plain.reasoning = .off
                result = try await sendOnce(
                    config: plain,
                    messages: messages,
                    tools: [],
                    onDelta: onDelta
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

            if round == maxRounds - 1 && usedTools {
                messages.append([
                    "role": "user",
                    "content": "（工具已经用完了，现在直接用你自己的话回我，别再调工具。）"
                ])
            }
        }
    }

    // MARK: - 单轮

    private static func sendOnce(
        config: LLMConfig,
        messages: [[String: Any]],
        tools: [DeviceTool],
        onDelta: @escaping (String) -> Void
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
        // 推理预算：关闭时不传这个字段（有些模型不认，传了反而报错）
        if let effort = config.reasoning.parameter {
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
}
