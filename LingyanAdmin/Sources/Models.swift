import Foundation

// MARK: - 账号（/api/auth/users）

struct UserItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var username: String { raw.s("username") }
    var isAdmin: Bool { raw.b("is_admin") }
    var isOwner: Bool { raw.b("is_owner") }
    var createdAt: String { raw.s("created_at") }
    var lastLogin: String { raw.s("last_login") }

    var roleLabel: String {
        if isOwner { return "站长" }
        return isAdmin ? "管理员" : "客户"
    }

    static func == (a: UserItem, b: UserItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 设备（/api/device/list）

struct DeviceItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var deviceCode: String { raw.s("device_code") }
    var name: String { raw.s("name") }
    var platform: String { raw.s("platform") }
    var appVersion: String { raw.s("app_version") }
    var status: String { raw.s("status") }
    var verifyCode: String { raw.s("verify_code") }
    var codeExpires: String { raw.s("code_expires") }
    var codeUsedAt: String { raw.s("code_used_at") }
    var codeUses: Int { raw.i("code_uses") }
    var expiresAt: String { raw.s("expires_at") }
    var note: String { raw.s("note") }
    var ip: String { raw.s("ip") }
    var ua: String { raw.s("ua") }
    var attempts: Int { raw.i("attempts") }
    var createdAt: String { raw.s("created_at") }
    var activatedAt: String { raw.s("activated_at") }
    var lastSeen: String { raw.s("last_seen") }

    var statusLabel: String {
        switch status {
        case "active": return "已授权"
        case "pending": return "待授权"
        case "blocked": return "已停用"
        case "": return "未知"
        default: return status
        }
    }

    var statusTint: Int {
        switch status {
        case "active": return 1
        case "pending": return 2
        case "blocked": return 3
        default: return 0
        }
    }

    var display: String { name.isEmpty ? deviceCode : name }

    static func == (a: DeviceItem, b: DeviceItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 卡密（/api/card/list）

struct CardItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var code: String { raw.s("code") }
    var planName: String { raw.s("plan_name") }
    var days: Int { raw.i("days") }
    var amount: Double { raw.d("amount") }
    var status: String { raw.s("status") }
    var username: String { raw.s("username") }
    var deviceCode: String { raw.s("device_code") }
    var deviceKey: String { raw.s("device_key") }
    var orderNo: String { raw.s("order_no") }
    var batch: String { raw.s("batch") }
    var note: String { raw.s("note") }
    var createdAt: String { raw.s("created_at") }
    var boundAt: String { raw.s("bound_at") }
    var expiresAt: String { raw.s("expires_at") }

    var statusLabel: String {
        switch status {
        case "unused": return "未使用"
        case "bound": return "已绑定"
        case "disabled": return "已停用"
        case "": return "未知"
        default: return status
        }
    }

    static func == (a: CardItem, b: CardItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 订单（/api/order/list/all）

struct OrderItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var orderNo: String { raw.s("order_no") }
    var plan: String { raw.s("plan") }
    var planName: String { raw.s("plan_name") }
    var amount: Double { raw.d("amount") }
    var days: Int { raw.i("days") }
    var deviceCode: String { raw.s("device_code") }
    var contact: String { raw.s("contact") }
    var note: String { raw.s("note") }
    var status: String { raw.s("status") }
    var verifyCode: String { raw.s("verify_code") }
    var ip: String { raw.s("ip") }
    var createdAt: String { raw.s("created_at") }
    var paidAt: String { raw.s("paid_at") }
    var doneAt: String { raw.s("done_at") }
    var doneBy: String { raw.s("done_by") }

    var statusLabel: String {
        switch status {
        case "pending": return "待处理"
        case "paid": return "已付款"
        case "done": return "已发码"
        case "canceled": return "已取消"
        case "": return "未知"
        default: return status
        }
    }

    static func == (a: OrderItem, b: OrderItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 登录流水（/api/audit/logins）

struct LoginRow: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var ts: String { raw.s("ts") }
    var username: String { raw.s("username") }
    var ok: Bool { raw.b("ok") }
    var ip: String { raw.s("ip") }
    var region: String { raw.s("region") }
    var city: String { raw.s("city") }
    var ua: String { raw.s("ua") }
    var note: String { raw.s("note") }

    var where_: String {
        let s = [region, city].filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? "—" : s
    }

    static func == (a: LoginRow, b: LoginRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - IP 封禁（/api/audit/blocks）

struct BlockRow: Identifiable, Hashable {
    let raw: [String: Any]

    var id: String { ip + "|" + reason }
    var ip: String { raw.s("ip") }
    var reason: String { raw.s("reason") }
    var until: String { raw.nz("until") }
    var createdAt: String { raw.s("created_at") }

    var untilLabel: String { until.isEmpty ? "永久" : Fmt.time(until) }

    static func == (a: BlockRow, b: BlockRow) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 对外 API Key（/api/oa/keys）

struct KeyItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var name: String { raw.s("name") }
    var owner: String { raw.s("owner") }
    var ownerName: String { raw.s("owner_name") }
    var hint: String { raw.s("hint") }
    var scopes: [String] { raw.strings("scopes") }
    var enabled: Bool { raw.b("enabled") }
    var note: String { raw.s("note") }
    var createdAt: String { raw.s("created_at") }
    var lastUsedAt: String { raw.nz("last_used_at") }
    var lastUsedIP: String { raw.s("last_used_ip") }
    /// 绑定在哪个管理员账号上；0 = 无主（站长转交给外部的合作方 Key）
    var userId: Int { raw.i("user_id") }

    var scopesLabel: String { scopes.isEmpty ? "—" : scopes.joined(separator: " + ") }
    var isExternal: Bool { userId <= 0 }

    static func == (a: KeyItem, b: KeyItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - 下载项（/api/pub/downloads）

struct DownloadItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: String { key }
    var key: String { raw.s("key") }
    var title: String { raw.s("title") }
    var note: String { raw.s("note") }
    var name: String { raw.s("name") }
    var size: Int { raw.i("size") }
    /// 实际下载地址（配了网盘就是网盘链接，否则是服务器直链）
    var url: String { raw.s("dl") }
    /// 下载去向：netdisk（网盘）/ direct（服务器直链）
    var target: String { raw.s("target") }

    var targetLabel: String {
        switch target {
        case "netdisk": return "百度网盘"
        case "direct": return "服务器直链"
        default: return "—"
        }
    }

    static func == (a: DownloadItem, b: DownloadItem) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}
