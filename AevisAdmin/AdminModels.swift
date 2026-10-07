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
    /// ⭐ 2026-10-07：有效期（秒）。0 / nil = 永久；86400 = 一天体验。
    var durationSeconds: Int?

    var id: String { code ?? UUID().uuidString }
    var isUsed: Bool { (usedAt ?? 0) > 0 }
    var isTrial: Bool { (durationSeconds ?? 0) > 0 }
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
    /// 封禁记录（2026-09-28 加）。老版本后端不返回这个字段 ——
    /// 所以是**可选**，解码不会炸。
    var events: [BanEvent]?
}

/// 一条封禁记录 —— 谁封的（自动 / 人工）、什么时候、**跨了哪几个网络**。
///
/// 这是封禁闭环的"案卷"。误封申诉全靠它：光说"你被封了"根本没法判断，
/// 得能看见"哦，他一天跨了 3 个网络"或者"这明显是误伤，赶紧解"。
struct BanEvent: Decodable, Identifiable {
    var id: Int?
    var email: String?
    var deviceId: String?
    /// 跨的那几个 IP —— 后端已经拼成 "1.2.3.4 / 5.6.7.8" 这种串了。
    var ips: String?
    var reason: String?
    var at: Int?
    var source: String?
    /// 有没有播报到群里（false = 桥还没轮到它）。
    var notified: Bool?

    /// ⚠️ 身份用字符串、不用 `id`：`id` 是**可选 Int**，
    /// `ForEach` 拿可选值当身份在重渲染时容易错位（`AdminOrder` 那次栽过）。
    var stableID: String { id.map(String.init) ?? (email ?? UUID().uuidString) }

    var isAuto: Bool { source == "auto" }
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

// MARK: - 弹性文本

/// 同一个字段**忽而是字符串、忽而是数字**的兜底解码。
///
/// SQLite 的列是弱类型的：`amount` 声明成 TEXT，但只要有人插进去一个数字，
/// 吐出来就是数字。直接 `decode(String.self)` 碰到数字会抛，
/// 而抛了整条记录就没了 —— 这类字段最容易把一整页变成空白
/// （本文件开头那条「宁可显示 —，也不能整页空」说的就是它）。
struct FlexText: Decodable {
    let text: String

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        // ⚠️ 这里**故意不写 `decodeNil()`**。两个原因：
        //   ① 它本来就不抛错（`SingleValueDecodingContainer.decodeNil()` 是 `-> Bool`），
        //      写 `try?` 会白吃一条编译警告（第一版就吃了）；
        //   ② 不写也不影响判空 —— JSON 的 `null` 落到下面三个 `try?` 全都会抛，
        //      最后自然走到 `text = ""`，和行为完全一致。
        if let value = try? box.decode(String.self) {
            text = value
        } else if let value = try? box.decode(Int.self) {
            text = String(value)
        } else if let value = try? box.decode(Double.self) {
            text = String(value)
        } else {
            text = ""
        }
    }

    /// 显示用：空就是「—」。
    var shown: String { text.isEmpty ? "—" : text }
}

// MARK: - 支付宝收款（监听服务抓的，只读）

struct AdminPayment: Decodable, Identifiable {
    var tradeNo: String?
    var amount: FlexText?
    var memo: String?
    var direction: String?
    var status: String?
    var buyer: String?
    var goods: String?
    /// ⚠️ 支付宝那边给的是**字符串**（`2026-09-27 23:13:50`），不是时间戳。
    var paidAt: String?
    var orderId: String?
    var seenAt: Int?

    var id: String { tradeNo ?? UUID().uuidString }
    /// 备注里认出了我们的订单号 —— 对上了才是"照订单付的这笔钱"。
    var isMapped: Bool { !(orderId ?? "").isEmpty }
}

struct AdminPaymentStats: Decodable {
    var total: Int?
    var mapped: Int?
    /// 后端是 `round(x, 2)` 出来的**数字**（不是字符串）。
    var amount: Double?
}

struct AdminPaymentList: Decodable {
    var items: [AdminPayment]?
    var stats: AdminPaymentStats?
}

// MARK: - PayPro 收款（内嵌的那个收款系统，只读）

struct AdminPayProOrder: Decodable, Identifiable {
    var id: String?
    /// 后端 `paypro_money()` 给的是**两位小数字符串**（如 "12.00"）。
    var amount: String?
    var actualAmount: String?
    var state: Int?
    var stateText: String?
    var payType: String?
    var payNum: String?
    var nickname: String?
    var email: String?
    var source: String?
    var createdAt: String?
    var paidAt: String?

    var payTypeLabel: String {
        switch payType {
        case "wechat": return "微信"
        case "alipay": return "支付宝"
        case "alipay_dmf": return "支付宝当面付"
        case "wechat_zs": return "微信赞赏"
        default: return payType?.isEmpty == false ? payType! : "—"
        }
    }
}

struct AdminPayProStats: Decodable {
    var total: Int?
    var paid: Int?
    var unpaid: Int?
}

struct AdminPayProList: Decodable {
    var ok: Bool?
    var why: String?
    var items: [AdminPayProOrder]?
    var stats: AdminPayProStats?
}

// MARK: - 购买订单

struct AdminOrder: Decodable, Identifiable {
    /// ⚠️ 订单号本身就是主键，后端 JSON 里的键就是 `id`（`AEXXXXXXXX`）。
    var id: String?
    var contact: String?
    var amount: FlexText?
    var createdAt: Int?
    var paidAt: Int?
    var paidBy: String?
    var paidNote: String?
    var unlockCode: String?
    var inviteCode: String?
    var mailOk: Int?
    var ip: String?

    var isPaid: Bool { (paidAt ?? 0) > 0 }
    var mailSent: Bool { (mailOk ?? 0) > 0 }
}

struct AdminOrderStats: Decodable {
    var total: Int?
    var paid: Int?
    var waiting: Int?
}

struct AdminOrderList: Decodable {
    var items: [AdminOrder]?
    var stats: AdminOrderStats?
}

// MARK: - 解锁码

struct AdminUnlockCode: Decodable, Identifiable {
    var code: String?
    var note: String?
    var price: FlexText?
    var issuedAt: Int?
    var firstUse: Int?
    var usedIp: String?
    var usedUa: String?
    var uses: Int?
    var disabled: Int?
    /// ⭐ 2026-10-07：有效期（秒）。0 / nil = 永久；86400 = 一天体验。
    var durationSeconds: Int?

    var id: String { code ?? UUID().uuidString }
    var isDisabled: Bool { (disabled ?? 0) > 0 }
    var isUsed: Bool { (uses ?? 0) > 0 }
    var isTrial: Bool { (durationSeconds ?? 0) > 0 }
}

struct AdminUnlockStats: Decodable {
    var total: Int?
    var used: Int?
    var disabled: Int?
}

struct AdminUnlockList: Decodable {
    var items: [AdminUnlockCode]?
    var stats: AdminUnlockStats?
}

struct IssuedUnlockCodes: Decodable {
    var ok: Bool?
    var codes: [String]?
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
