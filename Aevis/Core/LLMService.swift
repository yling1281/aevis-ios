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
            return "她这次没说话，再试一次。"
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
enum LLMService {

    static func streamReply(
        config: LLMConfig,
        systemPrompt: String,
        history: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await run(
                        config: config,
                        systemPrompt: systemPrompt,
                        history: history
                    ) { piece in
                        _ = continuation.yield(piece)
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

    private static func run(
        config: LLMConfig,
        systemPrompt: String,
        history: [ChatMessage],
        onDelta: @escaping (String) -> Void
    ) async throws {
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

        var payloadMessages: [[String: String]] = [
            ["role": "system", "content": systemPrompt]
        ]
        for item in history.suffix(40) {
            guard !item.text.isEmpty else { continue }
            payloadMessages.append([
                "role": item.role == .user ? "user" : "assistant",
                "content": item.text
            ])
        }

        let body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": payloadMessages
        ]
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

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String,
                  !piece.isEmpty else {
                continue
            }
            onDelta(piece)
        }
    }
}
