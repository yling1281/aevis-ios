import Foundation
import UIKit

// 管理端用到的所有数据结构。
//
// ⚠️ 这里**全是可选字段**，别改成必填 ——
// 后端加字段、改字段、某条记录缺某个值时，客户端宁可显示「—」，
// 也**不能因为一个字段解不出来就整个列表空白**（那是最让人抓狂的失败方式）。
//
// 解码时统一走 `keyDecodingStrategy = .convertFromSnakeCase`，
// 所以后端的 `new_today` 到这儿就是 `newToday`。

// MARK: - 总览

struct AdminStats: Decodable {
    var users: Int?
    var newToday: Int?
    var newWeek: Int?
    var loginsToday: Int?
    var activeWeek: Int?
    var codesPending: Int?
    var sendsToday: Int?
    var tokensLive: Int?

    /// 界面上按这个顺序摆（和网页后台一致）。
    var cells: [(String, Int?)] {
        [("用户总数", users), ("今日新增", newToday), ("7 天新增", newWeek),
         ("今日登录", loginsToday), ("7 天活跃", activeWeek),
         ("待用验证码", codesPending), ("今日发信", sendsToday), ("有效登录态", tokensLive)]
    }
}

// MARK: - 账号

struct AdminUser: Decodable, Identifiable {
    var email: String?
    var createdAt: Int?
    var lastLogin: Int?
    var blockedAt: Int?
    var blockedReason: String?
    var loginCount: Int?
    var lastIp: String?
    var lastUa: String?
    var deviceId: String?

    var id: String { email ?? UUID().uuidString }
    var isBlocked: Bool { (blockedAt ?? 0) > 0 }
}

struct AdminUserList: Decodable {
    var items: [AdminUser]?
    var admins: [String]?
    var warrantyDays: Int?
}

// MARK: - 注册码

struct AdminCode: Decodable, Identifiable {
    var code: String?
    var note: String?
    var issuedAt: Int?
    var usedAt: Int?
    var usedBy: String?

    var id: String { code ?? UUID().uuidString }
    var isUsed: Bool { (usedAt ?? 0) > 0 }
}

struct AdminCodeStats: Decodable {
    var total: Int?
    var used: Int?
}

struct AdminCodeList: Decodable {
    var items: [AdminCode]?
    var stats: AdminCodeStats?
}

struct IssuedCodes: Decodable {
    var ok: Bool?
    var codes: [String]?
}

// MARK: - 换机申请

struct DeviceRequest: Decodable, Identifiable {
    var id: Int?
    var email: String?
    var deviceId: String?
    var at: Int?
    var status: String?
    var currentDevice: String?

    var ident: String { String(id ?? 0) }
    var isPending: Bool { (status ?? "") == "pending" }
    var statusText: String {
        switch status ?? "" {
        case "pending": return "待处理"
        case "approved": return "已批准"
        case "rejected": return "已拒绝"
        default: return status ?? "—"
        }
    }
    /// `Identifiable` 用 id；这里是 Int? 所以单独给一个字符串版的。
    var stableID: String { "\(id ?? 0)-\(email ?? "")" }
}

struct DeviceRequestList: Decodable {
    var items: [DeviceRequest]?
}

// MARK: - 封禁

struct BlockedUser: Decodable, Identifiable {
    var email: String?
    var blockedAt: Int?
    var blockedReason: String?
    var id: String { email ?? UUID().uuidString }
}

struct BlockedDevice: Decodable, Identifiable {
    var deviceId: String?
    var blockedAt: Int?
    var reason: String?
    var id: String { deviceId ?? UUID().uuidString }
}

struct BlocksReply: Decodable {
    var users: [BlockedUser]?
    var devices: [BlockedDevice]?
}

// MARK: - 崩溃现场

struct DiagReport: Decodable, Identifiable {
    var code: String?
    var deviceId: String?
    var version: String?
    var os: String?
    var machine: String?
    var count: Int?
    var firstAt: Int?
    var lastAt: Int?
    var feedbackAt: Int?
    var feedbackNote: String?

    var id: String { "\(code ?? "?")/\(deviceId ?? "?")" }
    var isAnswered: Bool { (feedbackAt ?? 0) > 0 }
    var codeText: String { code ?? "—" }
}

/// 现场详情（比列表多一个 `body`，是崩之前那几十步的操作记录）。
struct DiagDetail: Decodable {
    var code: String?
    var deviceId: String?
    var version: String?
    var os: String?
    var machine: String?
    var count: Int?
    var firstAt: Int?
    var lastAt: Int?
    var feedbackAt: Int?
    var feedbackNote: String?
    var signed: Int?
    var body: String?
}

struct DiagReportList: Decodable {
    var ok: Bool?
    var items: [DiagReport]?
}

struct DiagDetailReply: Decodable {
    var ok: Bool?
    var item: DiagDetail?
}

/// 谁在群里问过这个错误码 —— 后台点「已反馈」之后，
/// 机器人照这张表去群里 @ 人（见 `server/qqbot/bot.py`）。
struct DiagAsker: Decodable, Identifiable {
    var qq: String?
    var groupId: String?
    var nickname: String?
    var askedAt: Int?
    var toldAt: Int?

    var id: String { "\(qq ?? "?")-\(askedAt ?? 0)" }
    var isTold: Bool { (toldAt ?? 0) > 0 }
}

struct DiagAskerList: Decodable {
    var ok: Bool?
    var items: [DiagAsker]?
}

// MARK: - 机器人

struct BotClaim: Decodable, Identifiable {
    var member: String?
    var group: String?
    var code: String?
    var at: Int?

    var id: String { "\(code ?? "?")-\(at ?? 0)" }
}

struct BotInfo: Decodable {
    var key: String?
    var tickets24h: Int?
    var claims: [BotClaim]?

    private enum K: String, CodingKey {
        case key, claims
        // ⚠️ 走 `.convertFromSnakeCase` 时，JSON 的 `tickets_24h` 会被转成
        //    `tickets24h`（`_2` 没法大写）—— 所以这里要按**转换后**的名字找。
        //    另一个名字留着兜底，哪天改了策略也还能解出来。
        case tickets24h
        case ticketsIn24h
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: K.self)
        key = try? box.decodeIfPresent(String.self, forKey: .key)
        claims = try? box.decodeIfPresent([BotClaim].self, forKey: .claims)
        tickets24h = (try? box.decodeIfPresent(Int.self, forKey: .tickets24h)) ?? nil
        if tickets24h == nil {
            tickets24h = (try? box.decodeIfPresent(Int.self, forKey: .ticketsIn24h)) ?? nil
        }
    }
}

// MARK: - 登录 / 后台账号

struct LoginReply: Decodable {
    var ok: Bool?
    var token: String?
    var email: String?
    var expiresIn: Int?
}

struct AdminAccountInfo: Decodable {
    var ok: Bool?
    var email: String?
    var username: String?
    var updatedAt: Int?
}

/// 只关心「成没成」的接口（删除、封禁、批准…）。
struct PlainReply: Decodable {
    var ok: Bool?
    var message: String?
}

// MARK: - 时间显示

/// 后端给的时间全是**秒级 unix 时间戳**，这里统一成人看的样子。
enum AdminFormat {
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// `2026-09-26 16:46`
    static func when(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "—" }
        return stamp.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// `刚刚` / `3 分钟前` / `2 天前`
    static func ago(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "" }
        let seconds = Int(Date().timeIntervalSince1970) - ts
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 86400 * 60 { return "\(seconds / 86400) 天前" }
        return ""
    }

    /// 拿来做「最后一步是什么」用 —— 诊断正文里每行开头都是 `HH:mm:ss`。
    static func lastLine(_ body: String?) -> String {
        guard let body, !body.isEmpty else { return "" }
        let lines = body.split(separator: "\n").map(String.init)
        return lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    }
}
