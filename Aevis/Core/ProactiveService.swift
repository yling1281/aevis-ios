import Foundation
import UserNotifications

enum BarkError: LocalizedError {
    case notConfigured
    case badURL
    case rejected(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有填 Bark 地址。"
        case .badURL:
            return "Bark 地址格式不对。应该是 https://api.day.app/你的KEY 这样。"
        case let .rejected(code, message):
            if code == 400 {
                return "Bark 说地址或参数不对（400）。检查 KEY 有没有抄错。"
            }
            return "Bark 返回 \(code)：\(message)"
        }
    }
}

/// 让 TA 主动找你。
///
/// 现实约束（必须先讲清楚）：
/// - 侧载的 App 用不了苹果的系统推送（没有对方的 APNs 密钥），所以主动消息靠**本地通知**，
///   它是系统级的，App 不运行也照样到点弹出来。
/// - 但「不定时」不能真的随机：本地通知只能在排程时把时间定下来。
///   所以做法是**每次打开 App 时，为接下来 24 小时重新随机排一批**。
/// - 她说的话不能临时生成（后台跑不了模型），所以是**提前生成一批存起来**，
///   排程时轮流取用。没填 API Key 时用内置兜底话术。
final class ProactiveService {
    static let shared = ProactiveService()

    private let center = UNUserNotificationCenter.current()
    private static let idPrefix = "aevis.proactive."

    private init() {}

    // MARK: - 授权

    func ensureAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    // MARK: - 排程

    /// 按当前设置重排全部主动消息。任何时候调用都安全（会先清掉旧的）。
    func reschedule() async {
        let settings = AppSettings.shared
        let persona = PersonaStore.shared.persona

        center.removePendingNotificationRequests(
            withIdentifiers: await pendingProactiveIdentifiers()
        )

        guard settings.proactiveEnabled else { return }

        // 截图自检时不弹系统权限框 —— 它会盖住大半个界面，
        // 让截图看不出真正的问题（这个是看截图时发现的）。
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-aevisDemo") { return }
        #endif

        _ = await ensureAuthorization()

        let lines = await linePool(persona: persona, settings: settings)
        guard !lines.isEmpty else { return }

        var cursor = 0
        func nextLine() -> String {
            let text = lines[cursor % lines.count]
            cursor += 1
            return text
        }

        // 定时：每天固定几个点，用重复触发器
        if settings.fixedTimesEnabled {
            for (index, time) in settings.fixedTimes.enumerated() {
                guard let (hour, minute) = Self.parse(time) else { continue }
                let content = makeContent(
                    title: persona.name.isEmpty ? "Aevis" : persona.name,
                    body: nextLine()
                )
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                let request = UNNotificationRequest(
                    identifier: Self.idPrefix + "fixed." + String(index),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }

        // 不定时：为接下来 24 小时随机排几条，一次性触发
        if settings.randomEnabled {
            let count = max(1, min(settings.randomPerDay, 6))
            let now = Date()
            for slot in 0..<count {
                // 把 24 小时分成 count 段，每段里随机取一个点，避免全挤在一起
                let windowLength = 24.0 * 3600.0 / Double(count)
                let offset = windowLength * Double(slot) + Double.random(in: 0..<windowLength)
                let fireAt = now.addingTimeInterval(max(offset, 300))
                let content = makeContent(
                    title: persona.name.isEmpty ? "Aevis" : persona.name,
                    body: nextLine()
                )
                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second],
                        from: fireAt
                    ),
                    repeats: false
                )
                let request = UNNotificationRequest(
                    identifier: Self.idPrefix + "random." + String(slot),
                    content: content,
                    trigger: trigger
                )
                try? await center.add(request)
            }
        }
    }

    private func pendingProactiveIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter {
                    $0.hasPrefix(Self.idPrefix)
                })
            }
        }
    }

    private func makeContent(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 她的话应该能穿透专注模式
        content.interruptionLevel = .timeSensitive
        return content
    }

    private static func parse(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    // MARK: - 话术池

    /// 取话术池；不够就先让模型写一批，写不出来用内置兜底。
    func linePool(persona: Persona, settings: AppSettings) async -> [String] {
        if settings.proactiveLines.count >= 4 {
            return settings.proactiveLines
        }
        if settings.isConfigured {
            let generated = await generateLines(
                persona: persona,
                config: settings.llm,
                count: 8
            )
            if generated.count >= 2 {
                settings.proactiveLines = generated
                return generated
            }
        }
        settings.proactiveLines = Self.fallbackLines
        return Self.fallbackLines
    }

    /// 让模型写一批「她会突然想对你说的话」。
    func generateLines(persona: Persona, config: LLMConfig, count: Int) async -> [String] {
        let prompt = """
        你叫\(persona.name)。用你自己的口吻写 \(count) 句「突然想对 TA 说的话」，
        就像平时聊天时你会主动发出去的那种消息。一句一行，不要编号，不要引号，不要解释。
        每句短一点，像真人发微信。
        """
        let history = [ChatMessage(role: .user, text: prompt)]

        var collected = ""
        do {
            for try await piece in LLMService.streamReply(
                config: config,
                systemPrompt: persona.systemPrompt,
                history: history
            ) {
                collected += piece
                if collected.count > 1200 { break }
            }
        } catch {
            return []
        }

        let lines = collected
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line -> String in
                var text = line
                for token in ["- ", "* ", "1. ", "\"", "「", "」"] {
                    text = text.replacingOccurrences(of: token, with: "")
                }
                // 去掉可能的行首序号
                while let first = text.first, first.isNumber {
                    text.removeFirst()
                }
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: ".、。 "))
                return text
            }
            .filter { !$0.isEmpty && $0.count <= 60 }

        return Array(lines.prefix(count))
    }

    /// 没填 API Key、或生成失败时用的兜底。
    static let fallbackLines: [String] = [
        "在干嘛呢",
        "突然想你了",
        "今天累不累",
        "记得喝水",
        "刚刚看到个东西想到你",
        "早点睡，别熬太晚",
        "有好好吃饭吗",
        "没什么事，就是想跟你说句话"
    ]

    // MARK: - Bark

    /// 往 Bark 推一条。地址形如 https://api.day.app/你的KEY ，也可自建。
    func sendBark(text: String, title: String, urlString: String) async throws {
        var base = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw BarkError.notConfigured }
        while base.hasSuffix("/") { base.removeLast() }

        guard let parsed = URL(string: base), let host = parsed.host, !host.isEmpty else {
            throw BarkError.badURL
        }
        // 设备 key 就是地址最后那一段：https://api.day.app/你的KEY
        let key = parsed.lastPathComponent

        // ——— 首选：POST + JSON ———
        //
        // 中文直接放在 JSON 正文里，**不用拼进 URL 做百分号转义**。
        // 之前走的是 `/<标题>/<内容>` 那种路径写法，中文会被转成一长串 %E5%…，
        // 用户看到的就是「符号转码」。
        if !key.isEmpty, let pushURL = URL(string: base + "/push") {
            var payload: [String: Any] = [
                "device_key": key,
                "title": title,
                "body": text,
                "group": "Aevis"
            ]
            payload["level"] = "timeSensitive"

            var request = URLRequest(url: pushURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

            if let result = try? await Self.perform(request) {
                return
            }
            // 失败就往下走兜底 —— 老版本 Bark 或自建服务可能没有 /push
        }

        // ——— 兜底：路径那种老写法（中文照旧要转义，但至少能用） ———
        guard var comps = URLComponents(string: base) else { throw BarkError.badURL }
        comps.path += "/" + Self.encode(title) + "/" + Self.encode(text)
        comps.queryItems = [
            URLQueryItem(name: "group", value: "Aevis"),
            URLQueryItem(name: "level", value: "timeSensitive")
        ]
        guard let url = comps.url else { throw BarkError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        _ = try await Self.perform(request)
    }

    /// 发一次请求，成功返回；失败抛出人话。
    private static func perform(_ request: URLRequest) async throws -> Bool {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw BarkError.rejected(code: code, message: "")
        }
        // Bark 正常会返回 {"code":200,"message":"success"}
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = object["code"] as? Int,
           inner != 200 {
            let message = (object["message"] as? String) ?? ""
            throw BarkError.rejected(code: inner, message: message)
        }
        return true
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
