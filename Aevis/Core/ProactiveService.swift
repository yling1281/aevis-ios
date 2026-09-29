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

    /// 请求通知权限。**只在用户主动去打开「主动消息」的时候调** ——
    /// 一进 App 就弹系统框太打扰，截图自检时还会盖住大半个界面。
    func ensureAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    /// 现在到底能不能发通知 —— **只问，不弹框**。
    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    // MARK: - 排程

    /// 按当前设置重排全部主动消息。任何时候调用都安全（会先清掉旧的）。
    func reschedule() async {
        let settings = AppSettings.shared
        let persona = PersonaStore.shared.persona
        // 「这些话说给谁听」—— 排程时把当前联系人记在通知里，
        // 弹出来之后好落回**对的那个会话**。
        // ⚠️ 回主线程读：`ChatStore` 是 `@Published`，在后台读它
        //    跟后台写一样会让 SwiftUI 收到别的线程的通知，iOS 26 上会崩（踩过）。
        let owner = await MainActor.run { ChatStore.shared.currentContactID?.uuidString }

        center.removePendingNotificationRequests(
            withIdentifiers: await pendingProactiveIdentifiers()
        )

        guard settings.proactiveEnabled else { return }

        // ⚠️ 这里**不再请求权限**，只检查有没有。
        //
        // 原来是在这儿调 ensureAuthorization() —— 结果每次启动都弹一次系统框：
        // 一进 App 就被问「要不要通知」很打扰；截图自检时那个框还会一直挂在
        // 屏幕上，把后面几张截图全盖住（真的是看截图才发现的）。
        //
        // 授权这件事应该由用户**主动**触发 —— 见「主动消息」卡片里那个按钮。
        #if DEBUG
        // 截图自检时不排程，省得启动路径上多出别的系统框
        if ProcessInfo.processInfo.arguments.contains("-aevisDemo") { return }
        #endif

        guard await isAuthorized() else { return }

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
                    body: nextLine(),
                    owner: owner
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
                    body: nextLine(),
                    owner: owner
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

    private func makeContent(title: String, body: String,
                             owner: String? = nil) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // 她的话应该能穿透专注模式
        content.interruptionLevel = .timeSensitive
        // ⚠️⚠️ **把正文塞进通知里带着走** —— 这是「弹窗消息要落进聊天记录」
        //    （用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的，像微信那样」）
        //    唯一可行的做法：本地通知在 App **没运行**的时候也在弹，那时候我们
        //    一行代码都执行不了。所以只能把这句话存在通知自己身上，
        //    等 App 一起来再补进聊天记录（见 `deliverPendingToChat`）。
        var info: [String: Any] = ["text": body]
        if let owner, !owner.isEmpty { info["persona"] = owner }
        content.userInfo = info
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

    // MARK: - 弹出来的话，补进聊天记录
    //
    // 用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的，像微信那样」
    //
    // 微信的行为是：通知弹出来，点进去**那条消息就在聊天里**。
    // 我们以前只弹通知、不落聊天 —— 用户点进去发现聊天里没有那句话，
    // 看起来就像"她说的这句丢了"。
    //
    // 两条路都要走，少一条就有场景漏：
    //   ① App 正在前台 → 系统先交给代理（`willPresent`），当场落进聊天；
    //   ② App 没运行 / 在后台 → 通知自己弹出去，**等 App 一起来**扫一遍
    //      "已送达但还没进聊天"的通知，补进去（`deliverPendingToChat`）。

    /// 从一条通知里把「她说了什么 + 说给谁」抠出来。
    static func payload(from notification: UNNotification) -> (text: String, owner: UUID?)? {
        let request = notification.request
        guard request.identifier.hasPrefix(idPrefix) else { return nil }
        let info = request.content.userInfo
        let text = (info["text"] as? String) ?? request.content.body
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let owner = (info["persona"] as? String).flatMap(UUID.init(uuidString:))
        return (text, owner)
    }

    /// 把「已经弹过、还没进聊天」的那几条补进去。
    ///
    /// 调用时机：App 启动、每次回到前台（`RootView`）。
    /// 处理完就把那条从"已送达"里删掉 —— 不删的话每次回前台都会重复补。
    @MainActor
    func deliverPendingToChat() async {
        let delivered = await center.deliveredNotifications()
        guard !delivered.isEmpty else { return }
        var handled: [String] = []
        for item in delivered {
            guard let payload = Self.payload(from: item) else { continue }
            ChatStore.shared.appendProactive(payload.text, for: payload.owner)
            handled.append(item.request.identifier)
        }
        if !handled.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: handled)
        }
    }

    /// 前台时系统先把通知交给我们（[`willPresent`]）—— 那就当场落进聊天。
    @MainActor
    func absorbForegroundNotification(_ notification: UNNotification) {
        guard let payload = Self.payload(from: notification) else { return }
        ChatStore.shared.appendProactive(payload.text, for: payload.owner)
        // 从"已送达"里删掉：不然回前台那次扫描会把它再补一遍。
        center.removeDeliveredNotifications(withIdentifiers: [notification.request.identifier])
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

            // 成功就到此为止；失败往下走兜底。
            // 用 `!= nil` 而不是 `if let result =`：返回值我们**根本不用**，
            // 绑定一个从来没人读的变量只会让编译器警告。
            if (try? await Self.perform(request)) != nil {
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


/// 通知代理。
///
/// 只干一件事：**App 正在前台时，把那条通知当场塞进聊天记录，且不弹横幅**。
/// 用户就在 App 里看着，再弹个横幅纯属噪音（微信也是这个行为）。
final class ProactiveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    static let shared = ProactiveNotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await ProactiveService.shared.absorbForegroundNotification(notification)
        return []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // 用户点了通知 → 那条话必须已经在聊天里（点进来看得见）。
        await ProactiveService.shared.absorbForegroundNotification(response.notification)
    }
}
