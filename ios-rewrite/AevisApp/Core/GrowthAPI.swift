import Foundation

/// 增长 / 创作者 / 对话日志 / 每日签到的调用层（2.8）。
///
/// 后端四个增长接口与签到接口**尚未全部上线**：一律「取不到就显示暂无数据」，
/// 不编造活动、不写死群链接、不伪造邀请奖励。两个读接口走硬缓存
/// （每次进页面强制刷新，失败用上次缓存）；写接口（绑定邀请码、签到）直连，不缓存结果。
enum GrowthAPI {

    // MARK: - 模型

    struct GrowthConfig {
        var groupJoinUrl: String = ""
        var wechatWorkUrl: String = ""
        var activityUrl: String = ""
        var inviteBaseUrl: String = ""

        var hasAnyEntry: Bool {
            !groupJoinUrl.isEmpty || !wechatWorkUrl.isEmpty
                || !activityUrl.isEmpty || !inviteBaseUrl.isEmpty
        }
    }

    struct GrowthActivity: Identifiable {
        let id: String
        var title: String = ""
        var summary: String = ""
        var url: String = ""
        var rewardPoints: Int = 0
        var startAt: String = ""
        var endAt: String = ""
    }

    struct ChatLogEntry: Identifiable {
        let id: String
        var role: String = ""
        var content: String = ""
        var createdAt: String = ""
    }

    struct InviteResult {
        var ok: Bool = false
        var points: Int = 0
        var message: String = ""
    }

    struct CheckInStatus {
        var done: Bool = false
        var monthCount: Int = 0
        var streak: Int = 0
        var totalPoints: Int = 0
        var nextReward: Int = 0
        var multiplier: Int = 1
        var memberBoost: Bool = false
    }

    struct CheckInResult {
        var already: Bool = false
        var points: Int = 0
        var streak: Int = 0
        var multiplier: Int = 1
        var memberBoost: Bool = false
    }

    // MARK: - 小工具

    private static func data(_ json: [String: Any]) -> [String: Any] {
        (json["data"] as? [String: Any]) ?? json
    }

    private static func stringID(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - GET /v1/growth/config

    /// 每次进页面都调一次（ttl=1 等价于刷新），拿到新链接立刻覆盖硬缓存；
    /// 断网时用上次缓存，链接不会变成空串或写死值。
    static func config(force: Bool = true) async -> GrowthConfig? {
        let json = try? await APIClient.cacheAndFetch(
            .growthConfig, path: "/v1/growth/config", ttl: force ? 1 : 600)
        guard let json else {
            guard let stale = APIClient.cachedJSON(.growthConfig) else { return nil }
            return parseConfig(stale)
        }
        return parseConfig(json)
    }

    static func parseConfig(_ json: [String: Any]) -> GrowthConfig {
        let d = data(json)
        return GrowthConfig(
            groupJoinUrl: (d["groupJoinUrl"] as? String) ?? "",
            wechatWorkUrl: (d["wechatWorkUrl"] as? String) ?? "",
            activityUrl: (d["activityUrl"] as? String) ?? "",
            inviteBaseUrl: (d["inviteBaseUrl"] as? String) ?? ""
        )
    }

    // MARK: - GET /v1/growth/activities

    static func activities() async -> [GrowthActivity] {
        let json = try? await APIClient.cacheAndFetch(
            .growthActivities, path: "/v1/growth/activities", ttl: 300)
        guard let json else {
            guard let stale = APIClient.cachedJSON(.growthActivities) else { return [] }
            return parseActivities(stale)
        }
        return parseActivities(json)
    }

    static func parseActivities(_ json: [String: Any]) -> [GrowthActivity] {
        let d = data(json)
        let rows = (d["rows"] as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = stringID(r["id"]) else { return nil }
            return GrowthActivity(
                id: id,
                title: (r["title"] as? String) ?? "",
                summary: (r["summary"] as? String) ?? "",
                url: (r["url"] as? String) ?? "",
                rewardPoints: (r["rewardPoints"] as? NSNumber)?.intValue ?? 0,
                startAt: (r["startAt"] as? String) ?? "",
                endAt: (r["endAt"] as? String) ?? ""
            )
        }
    }

    // MARK: - POST /v1/growth/invite/bind

    static func bindInvite(code: String) async -> InviteResult {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return InviteResult(message: "请先填写邀请码")
        }
        do {
            let json = try await APIClient.request(
                "/v1/growth/invite/bind", method: "POST", body: ["code": trimmed])
            let d = data(json)
            return InviteResult(
                ok: (d["ok"] as? Bool) ?? false,
                points: (d["points"] as? NSNumber)?.intValue ?? 0,
                message: (d["message"] as? String) ?? (json["msg"] as? String) ?? ""
            )
        } catch {
            return InviteResult(message: error.localizedDescription)
        }
    }

    // MARK: - GET /v1/chat/logs?cursor&limit

    /// 第一页落硬缓存，翻页不缓存（cursor 是会话状态，缓存下来反而会错页）。
    static func chatLogs(
        cursor: String?, token: String? = nil, limit: Int = 20
    ) async -> (rows: [ChatLogEntry], nextCursor: String?) {
        let isFirst = (cursor ?? "").isEmpty
        var path = "/v1/chat/logs?limit=\(limit)"
        if let cursor, !cursor.isEmpty {
            let enc = cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor
            path += "&cursor=\(enc)"
        }
        do {
            let json: [String: Any]
            if isFirst {
                json = try await APIClient.cacheAndFetch(
                    .chatLogs, path: path, scope: APIClient.cacheScope, ttl: 60, token: token)
            } else {
                json = try await APIClient.request(path, token: token)
            }
            return parseChatLogs(json)
        } catch {
            guard isFirst, let stale = APIClient.cachedJSON(.chatLogs, scope: APIClient.cacheScope) else {
                return ([], nil)
            }
            return parseChatLogs(stale)
        }
    }

    static func parseChatLogs(_ json: [String: Any]) -> (rows: [ChatLogEntry], nextCursor: String?) {
        let d = data(json)
        let rows = (d["rows"] as? [[String: Any]]) ?? []
        let parsed = rows.compactMap { r -> ChatLogEntry? in
            guard let id = stringID(r["id"]) else { return nil }
            return ChatLogEntry(
                id: id,
                role: (r["role"] as? String) ?? "",
                content: (r["content"] as? String) ?? "",
                createdAt: (r["createdAt"] as? String) ?? ""
            )
        }
        let next = (d["nextCursor"] as? String) ?? ""
        return (parsed, next.isEmpty ? nil : next)
    }

    // MARK: - 签到（后端已上线，字段照 aevis_checkin.py）

    static func checkinStatus(token: String) async -> CheckInStatus? {
        guard let json = try? await APIClient.request("/v1/checkin/status", token: token) else {
            return nil
        }
        let d = data(json)
        return CheckInStatus(
            done: (d["done"] as? Bool) ?? false,
            monthCount: (d["monthCount"] as? NSNumber)?.intValue ?? 0,
            streak: (d["streak"] as? NSNumber)?.intValue ?? 0,
            totalPoints: (d["totalPoints"] as? NSNumber)?.intValue ?? 0,
            nextReward: (d["nextReward"] as? NSNumber)?.intValue ?? 0,
            multiplier: (d["multiplier"] as? NSNumber)?.intValue ?? 1,
            memberBoost: (d["memberBoost"] as? Bool) ?? false
        )
    }

    static func doCheckin(token: String) async -> CheckInResult? {
        guard let json = try? await APIClient.request(
            "/v1/checkin", method: "POST", body: [:], token: token) else { return nil }
        let d = data(json)
        return CheckInResult(
            already: (d["already"] as? Bool) ?? false,
            points: (d["points"] as? NSNumber)?.intValue ?? 0,
            streak: (d["streak"] as? NSNumber)?.intValue ?? 0,
            multiplier: (d["multiplier"] as? NSNumber)?.intValue ?? 1,
            memberBoost: (d["memberBoost"] as? Bool) ?? false
        )
    }
}
