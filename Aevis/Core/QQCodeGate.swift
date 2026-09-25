import Foundation

/// QQ 机器人发注册码：**关键词触发 → 群里拿口令 → 私聊换码**。
///
/// ## ⚠️ 这条路**现在没在用**（2026-09-25 起）
/// 用户后来把发码整个搬到了**服务器**上：群里的机器人（`server/qqbot/bot.py`）
/// 收到「注册」就当场回一张码，不再需要口令、也不需要 App 参与。
/// 这个文件**目前没有任何界面能打开它**（`qqBotCodeEnabled` 出厂 false，
/// 设置里那一节已经删掉了），留着是因为逻辑本身是对的 ——
/// 万一以后要让"用户自己手机上的机器人"也能发码，改一个入口就能复活。
///
/// 清理的时候记得一起看：`AppSettings.qqBotCode*`、`BuiltInSecrets.accountBotKey`、
/// `scripts/inject_secrets.py` 里的 `AEVIS_ACCOUNT_BOT_KEY`、
/// 服务端 `POST /api/bot/ticket|claim` 和 `bot_tickets`/`bot_claims` 两张表。
///
/// ---
///
/// ## 用户当初的口径
/// 指定关键词、**私聊发码**、必须是群成员、一个 QQ 只给一张。
///
/// ## ⚠️ 为什么绕成两步（这不是我图省事，是官方限制）
/// 原本最自然的做法是"私聊发关键词 → 直接发码"，但前提是**能验证他是群成员**，
/// 而这个前提在官方接口上不成立：
///
/// 1. 官方**有**「获取群成员列表」（`GET /v2/groups/{group_openid}/members`），
///    但文档写着「**该能力正在内邀接入中**」，错误码 `11253` 也明说
///    「该接口仅白名单机器人可用，请联系平台运营申请权限」。
/// 2. 更要命的是标识对不上：**私聊用的是 `user_openid`，群聊用的是 `member_openid`**，
///    是两个不同的值（官方原话：不同场景的 openid 不相同）。所以就算拿到了群成员列表，
///    也**没法知道发私聊的这个人是不是列表里的某一个**。
///
/// 于是把"证明他在群里"这件事**搬回群里做** —— 他能在群里 @ 到机器人，
/// 这件事本身就是"他是群成员"的证据，不需要任何接口。口令只负责把
/// 「群里那个人」和「待会儿私聊这个人」串起来。
///
/// ## 口令是公开的，所以做短命
/// 口令贴在群里，理论上别人能看到并抢先兑。但它：
/// - **3 分钟**就过期、**只能用一次**
/// - 抢的人也是群成员，本来就在允许的范围内（不破坏"只给群里的人"）
/// - 一个 QQ 只能领一张，抢到了也不多拿
/// 所以代价只是"某人需要回群里再要一个"，可以接受。
final class QQCodeGate {

    static let shared = QQCodeGate()

    private init() {}

    /// 账号后端的地址。**必须和服务器上部署的一致。**
    /// 改域名的话改这一行（只有一处）。
    private let server = "https://account.lingyan.cyou"

    /// 关键词后面跟的那一串，必须长得像口令才认（字母数字、4–12 位）。
    /// 为什么要有这个限制：不然「注册码是多少」这种话会被当成
    /// "关键词 + 口令 = 码是多少"，然后拿这句中文去查口令 → 报"口令不对"。
    private static let ticketChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    // MARK: - 门槛

    private var settings: AppSettings { AppSettings.shared }

    private var keyword: String {
        let raw = settings.qqBotCodeKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "注册" : raw
    }

    /// 钥匙：**用户填的优先，没填才看内置的**。
    /// 内置值走 CI 编译时注入（`BuiltInSecrets`），仓库里永远是空的。
    private var key: String {
        let typed = settings.qqBotCodeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return BuiltInSecrets.accountBotKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var enabled: Bool { settings.qqBotCodeEnabled }

    // MARK: - 认关键词

    /// 从一条消息里认出关键词。
    ///
    /// - 返回 `nil` = **不是关键词**，交给模型正常聊天
    /// - 返回 `""` = 是关键词，但没带口令
    /// - 返回 `"ABC123"` = 是关键词，而且带了口令
    func keywordArgument(in raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // QQ 群里 @ 机器人之后，正文有时候还带着「@某某 」这一截，先剥掉
        if text.hasPrefix("@") {
            if let gap = text.firstIndex(where: { $0 == " " || $0 == "\u{3000}" }) {
                text = String(text[text.index(after: gap)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let word = keyword
        guard !word.isEmpty else { return nil }
        if text == word { return "" }
        guard text.hasPrefix(word) else { return nil }

        let rest = String(text.dropFirst(word.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return "" }

        let candidate = rest.uppercased()
        let looksLikeTicket = candidate.count >= 4 && candidate.count <= 12
            && candidate.unicodeScalars.allSatisfy { Self.ticketChars.contains($0) }
        return looksLikeTicket ? candidate : ""
    }

    // MARK: - 私聊：换码

    /// 私聊里收到消息 → 要么给码，要么告诉他怎么拿。返回 nil = 不拦截，正常聊天。
    func handlePrivate(text: String, c2cOpenID: String) async -> String? {
        guard let ticket = keywordArgument(in: text) else { return nil }
        // 功能没开 = 不拦截，她照常聊天（免得没开的时候关键词变成一句固定回话）
        guard enabled else { return nil }

        guard !key.isEmpty else {
            return "发注册码的功能还没配好：缺服务器的钥匙。\n"
                + "（管理员去 account.lingyan.cyou/admin 复制「发码钥匙」，"
                + "填进 App 的「我 → 设置 → QQ 机器人 → 发注册码」。）"
        }
        guard !c2cOpenID.isEmpty else { return nil }

        do {
            let json = try await post("/api/bot/claim",
                                      ["ticket": ticket, "c2c_openid": c2cOpenID])
            if let code = json["code"] as? String, !code.isEmpty {
                let base = (json["register_base"] as? String) ?? server
                if json["already"] as? Bool == true {
                    return "你之前领过了，就是这张：\n\n\(code)\n\n去 \(base) 点「注册」就行。"
                }
                return "给你注册码：\n\n\(code)\n\n"
                    + "去 \(base) 点「注册」，填这个码 + 你的邮箱，"
                    + "再收一封邮件里的验证码就成了。\n"
                    + "（一码一人，别转给别人。）"
            }
            return Self.explain(json)
        } catch {
            return "发码这条链路上出问题了：" + error.localizedDescription
        }
    }

    // MARK: - 群里：口令

    /// 群里被 @ 到 → 发一个口令。返回 nil = 不拦截。
    func handleGroup(text: String, group: String, member: String) async -> String? {
        guard keywordArgument(in: text) != nil else { return nil }
        guard enabled else { return nil }
        guard !key.isEmpty else { return nil }

        // 限定群：设了白名单就只管那几个群，别的群一句都不回
        let allowed = settings.qqBotCodeGroups
        if !allowed.isEmpty, !allowed.contains(group) { return nil }
        guard !group.isEmpty, !member.isEmpty else { return nil }

        do {
            let json = try await post("/api/bot/ticket",
                                      ["group_openid": group, "member_openid": member])
            guard let ticket = json["ticket"] as? String, !ticket.isEmpty else {
                return Self.explain(json)
            }
            let minutes = max(1, (json["expires_in"] as? Int ?? 180) / 60)
            return "口令：\(ticket)\n\n"
                + "\(minutes) 分钟内私聊我（点我头像 → 发消息），发这句：\n"
                + "\(keyword) \(ticket)\n\n"
                + "（一个 QQ 只能领一张注册码，这个口令只能用一次。）"
        } catch {
            return "换口令没成功：" + error.localizedDescription
        }
    }

    // MARK: - 把服务器的错误说成人话

    /// 服务器回的是 `{"error": "...", "message": "..."}`。
    /// 这里按错误码给一句**用户看了知道下一步干什么**的话 ——
    /// 直接甩"400 bad_ticket"他只会以为坏了。
    private static func explain(_ json: [String: Any]) -> String {
        let code = (json["error"] as? String) ?? ""
        switch code {
        case "need_ticket":
            return "注册码只发给群里的成员。\n\n"
                + "先去群里 @我 发一句「\(AppSettings.shared.qqBotCodeKeyword.isEmpty ? "注册" : AppSettings.shared.qqBotCodeKeyword)」，"
                + "我给你一个口令，回来私聊我发「关键词 + 口令」就能领到。"
        case "bad_ticket":
            return "这个口令对不上。回群里再 @我 要一个吧。"
        case "ticket_expired":
            return "口令过期了（只有几分钟）。回群里再 @我 要一个。"
        case "ticket_used":
            return "这个口令刚被用掉了。回群里再 @我 要一个新的。"
        case "already_claimed", "member_claimed":
            return "你这边已经领过注册码了，一个 QQ 只能领一张。\n找不到的话去邮箱里翻一翻。"
        case "too_fast":
            let wait = json["retry_after"] as? Int ?? 45
            return "别急，\(wait) 秒之后再试一次。"
        case "group_busy":
            return "这个群刚才要得太频繁了，等一会儿再来。"
        case "hourly_cap":
            return "今天发得有点多，先停一停，过会儿再来。"
        case "unauthorized":
            return "服务器不认我这边的钥匙，发不出注册码。让管理员重新核对一下「发码钥匙」。"
        default:
            let message = (json["message"] as? String) ?? ""
            return message.isEmpty ? "这次没成功，过会儿再试一次。" : message
        }
    }

    // MARK: - 网络

    private func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: server + path) else {
            throw QQCodeError.badURL(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "X-Bot-Key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw QQCodeError.unreachable(error.localizedDescription)
        }

        // ⚠️ 4xx **不当作异常** —— 里面的 message 正是要给用户看的那句话
        // （"口令过期了""已经领过了"）。当成异常丢掉的话，用户只会看到
        // 一句"服务器错误"，完全不知道下一步该干嘛。
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw QQCodeError.badResponse(status, String(decoding: data.prefix(120), as: UTF8.self))
        }
        return json
    }
}

enum QQCodeError: LocalizedError {
    case badURL(String)
    case unreachable(String)
    case badResponse(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL(let path):
            return "地址拼错了（\(path)）。"
        case .unreachable(let reason):
            return "连不上发码服务器：\(reason)"
        case .badResponse(let status, let body):
            return "服务器回了个看不懂的东西（HTTP \(status)：\(body)）"
        }
    }
}
