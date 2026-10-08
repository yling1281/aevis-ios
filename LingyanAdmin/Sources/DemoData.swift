import Foundation

/// `-demo` 启动参数下的假数据。
///
/// 为什么要它：CI 里的**截图自检**要能拍到每一页，但截图时不能带着真的账号密码
/// （仓库是公开的，密码写进 workflow 就等于公开泄露）。所以给一个纯本地假数据模式，
/// 界面结构照常渲染，一个网络请求都不发。
///
/// ⚠️ 它必须能**绕过「没登录就先显示登录页」那道门**，
///    否则所有截图都会是同一屏登录页（编译一路绿，图全废）。
enum DemoData {
    // MARK: 总览 / 审计

    static var audit: [String: Any] {
        ["ok": true,
         "today": ["logins_ok": 18, "logins_fail": 2, "users": 7, "ips": 9],
         "users_total": 11,
         "online": 3,
         "trend": [
            ["day": "2026-10-02", "logins": 11, "users": 4],
            ["day": "2026-10-03", "logins": 15, "users": 5],
            ["day": "2026-10-04", "logins": 9, "users": 3],
            ["day": "2026-10-05", "logins": 21, "users": 8],
            ["day": "2026-10-06", "logins": 17, "users": 6],
            ["day": "2026-10-07", "logins": 24, "users": 9],
            ["day": "2026-10-08", "logins": 18, "users": 7],
         ],
         "top_today": [
            ["username": "零砚", "hits": 42, "last_seen": "2026-10-08T18:31:00"],
            ["username": "客户甲", "hits": 13, "last_seen": "2026-10-08T17:02:00"],
            ["username": "客户乙", "hits": 5, "last_seen": "2026-10-08T11:40:00"],
         ],
         "blocked": [
            ["ip": "45.12.77.9", "reason": "爆破攻击自动永久封禁(30分钟内失败≥12次)",
             "until": "", "created_at": "2026-10-06T03:12:00"],
         ],
         "rate_limit_note": "异常高频访问与暴力撞库会被自动拦截并封禁 IP"]
    }

    static var logins: [LoginRow] {
        [
            ["id": 3, "ts": "2026-10-08T18:31:00", "username": "零砚", "ok": true,
             "ip": "115.152.113.77", "region": "福建", "city": "厦门",
             "ua": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)", "note": ""],
            ["id": 2, "ts": "2026-10-08T17:58:00", "username": "someone", "ok": false,
             "ip": "45.12.77.9", "region": "海外", "city": "",
             "ua": "python-requests/2.31", "note": "账号或密码错误"],
            ["id": 1, "ts": "2026-10-08T09:02:00", "username": "客户甲", "ok": true,
             "ip": "112.17.240.3", "region": "浙江", "city": "杭州",
             "ua": "零砚素材管理器/1.4.3", "note": "新 IP 登录"],
        ].map { LoginRow(raw: $0) }
    }

    static var activity: [[String: Any]] {
        [
            ["username": "零砚", "ip": "115.152.113.77", "hits": 42,
             "last_seen": "2026-10-08T18:31:00", "region": "福建", "city": "厦门"],
            ["username": "客户甲", "ip": "112.17.240.3", "hits": 13,
             "last_seen": "2026-10-08T17:02:00", "region": "浙江", "city": "杭州"],
            ["username": "客户乙", "ip": "223.104.9.88", "hits": 5,
             "last_seen": "2026-10-08T11:40:00", "region": "广东", "city": "深圳"],
        ]
    }

    static var blocks: [[String: Any]] {
        [["ip": "45.12.77.9", "reason": "爆破攻击自动永久封禁(30分钟内失败≥12次)",
          "until": "", "created_at": "2026-10-06T03:12:00"]]
    }

    // MARK: 设备

    static var deviceStats: [String: Any] {
        ["pending": 1, "active": 2, "blocked": 0, "online": 1,
         "activated_7d": 2, "trend": [], "today": "2026-10-08"]
    }

    static var devices: [DeviceItem] {
        [
            ["id": 2, "device_code": "A9B5-E862-5B9C-1F30", "name": "零砚的工作机",
             "platform": "Windows 11", "app_version": "1.4.3", "status": "active",
             "verify_code": "K7M2-QP4X", "code_expires": "2027-10-08T10:00:00",
             "code_issued": "2026-09-18T10:00:00", "code_used_at": "2026-09-18T10:05:00",
             "code_uses": 3, "code_last_used": "2026-10-08T18:20:00",
             "token_tail": "eyJhbGciOiJI…", "token_expires": "2027-10-08T10:00:00",
             "expires_at": "2027-10-08T10:00:00", "note": "主力机",
             "ip": "115.152.113.77", "ua": "零砚素材管理器/1.4.3", "attempts": 0,
             "created_at": "2026-09-18T10:00:00", "activated_at": "2026-09-18T10:05:00",
             "last_seen": "2026-10-08T18:31:00"],
            ["id": 1, "device_code": "9F8E-7D6C-5B4A-3210", "name": "备用机",
             "platform": "Windows 10", "app_version": "1.4.2", "status": "active",
             "verify_code": "R3T8-WN5B", "code_expires": "2027-01-02T09:00:00",
             "code_issued": "2026-10-01T09:20:00", "code_used_at": "2026-10-01T09:25:00",
             "code_uses": 1, "code_last_used": "2026-10-07T22:00:00",
             "token_tail": "eyJhbGciOiJI…", "token_expires": "2027-01-02T09:00:00",
             "expires_at": "2027-01-02T09:00:00", "note": "",
             "ip": "115.152.113.77", "ua": "零砚素材管理器/1.4.2", "attempts": 0,
             "created_at": "2026-09-30T09:20:00", "activated_at": "2026-10-01T09:25:00",
             "last_seen": "2026-10-07T22:05:00"],
        ].map { DeviceItem(raw: $0) }
    }

    // MARK: 卡密

    static var cardStats: [String: Any] {
        ["unused": 37, "bound": 2, "disabled": 0, "today": 5]
    }

    static var cards: [CardItem] {
        [
            ["id": 101, "code": "LY-7K2M-QP4X", "plan_name": "年费会员", "days": 365,
             "amount": 128.0, "status": "bound", "username": "客户甲",
             "device_code": "A9B5-E862-5B9C-1F30", "device_key": "DK-8821-AB",
             "order_no": "OD20261001120001", "batch": "B2610011200-K3D", "note": "",
             "created_at": "2026-10-01T12:00:00", "bound_at": "2026-10-01T12:05:00",
             "expires_at": "2027-10-01T12:05:00"],
            ["id": 100, "code": "LY-3D9F-TW8N", "plan_name": "月费会员", "days": 30,
             "amount": 15.0, "status": "unused", "username": "", "device_code": "",
             "device_key": "", "order_no": "", "batch": "B2610080930-M2P", "note": "",
             "created_at": "2026-10-08T09:30:00", "bound_at": "", "expires_at": ""],
        ].map { CardItem(raw: $0) }
    }

    // MARK: 订单

    static var orderStats: [String: Any] {
        ["pending": 1, "paid": 0, "done": 2, "canceled": 0, "today": 1,
         "income": 256.0, "income_today": 128.0]
    }

    static var orders: [OrderItem] {
        [
            ["id": 12, "order_no": "OD20261008121130", "plan": "year", "plan_name": "年费会员",
             "amount": 128.0, "days": 365, "device_code": "A9B5-E862-5B9C-1F30",
             "contact": "QQ 1234567", "note": "客户说转好了", "status": "pending",
             "verify_code": "", "device_id": 2, "ip": "112.17.240.3",
             "created_at": "2026-10-08T12:11:30", "paid_at": "", "done_at": "",
             "done_by": ""],
            ["id": 11, "order_no": "OD20261001120001", "plan": "year", "plan_name": "年费会员",
             "amount": 128.0, "days": 365, "device_code": "A9B5-E862-5B9C-1F30",
             "contact": "微信 lingyan", "note": "", "status": "done",
             "verify_code": "K7M2-QP4X", "device_id": 2, "ip": "112.17.240.3",
             "created_at": "2026-10-01T12:00:00", "paid_at": "2026-10-01T12:03:00",
             "done_at": "2026-10-01T12:04:00", "done_by": "零砚"],
        ].map { OrderItem(raw: $0) }
    }

    // MARK: 账号

    static var users: [UserItem] {
        [
            ["id": 1, "username": "零砚", "is_admin": true, "is_owner": true,
             "created_at": "2026-09-01T08:00:00", "last_login": "2026-10-08T18:31:00"],
            ["id": 6, "username": "客服小七", "is_admin": true, "is_owner": false,
             "created_at": "2026-09-20T10:00:00", "last_login": "2026-10-07T20:11:00"],
            ["id": 5, "username": "客户甲", "is_admin": false, "is_owner": false,
             "created_at": "2026-10-01T12:00:00", "last_login": "2026-10-08T17:02:00"],
        ].map { UserItem(raw: $0) }
    }

    // MARK: 对外 API

    static var mineKey: [String: Any] {
        ["id": 5, "name": "我的 Key", "owner": "零砚", "user_id": 1, "owner_name": "零砚",
         "hint": "LYAPI-7K2M…QP4X", "scopes": ["card", "read"], "enabled": true,
         "note": "", "created_at": "2026-10-08T13:00:00",
         "last_used_at": "2026-10-08T18:20:00", "last_used_ip": "115.152.113.77"]
    }

    static var keys: [[String: Any]] {
        [
            mineKey,
            ["id": 1, "name": "磁力素材网", "owner": "零砚", "user_id": 0, "owner_name": "",
             "hint": "LYAPI-3D9F…TW8N", "scopes": ["card"], "enabled": true,
             "note": "合作方，只能拿码/验证", "created_at": "2026-10-07T10:00:00",
             "last_used_at": "2026-10-08T16:40:00", "last_used_ip": "45.77.12.9"],
            ["id": 6, "name": "客服小七的 Key", "owner": "客服小七", "user_id": 6,
             "owner_name": "客服小七", "hint": "LYAPI-8H4L…M2QQ", "scopes": ["card"],
             "enabled": true, "note": "", "created_at": "2026-10-08T10:00:00",
             "last_used_at": "", "last_used_ip": ""],
        ]
    }

    // MARK: 下载去向

    static var dlConfig: [[String: Any]] {
        [
            ["key": "desktop", "title": "桌面完整版",
             "file": "零砚素材管理器-单机版.exe", "file_ok": true,
             "legacy": "/download/win", "url": "", "code": "", "final": "", "mode": "direct"],
            ["key": "web", "title": "网页版客户端",
             "file": "零砚素材管理器-网页版.exe", "file_ok": true,
             "legacy": "/download/web", "url": "", "code": "", "final": "", "mode": "direct"],
            ["key": "plugin", "title": "零砚 Animate 插件（二合一）",
             "file": "零砚Animate插件安装程序.exe", "file_ok": true,
             "legacy": "/api/pub/download/plugin",
             "url": "https://pan.baidu.com/s/1demoDEMOdemo", "code": "ly88",
             "final": "https://pan.baidu.com/s/1demoDEMOdemo?pwd=ly88", "mode": "netdisk"],
        ]
    }
}
