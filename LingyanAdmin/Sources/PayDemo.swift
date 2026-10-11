import Foundation

/// 码支付后台的**演示数据**（`-demo` 启动时全用它，一个网络请求都不发）。
///
/// ⚠️ 为什么必须有它：云编译流水线会把模拟器截图打进 Release（公开可见）。
///    用真数据截图 = 把通道号、账号名、金额泄到公开仓库里。
///    所以这里的**每一个值都是编的**：账号写成「支付宝账号1」这种，
///    不出现任何真实收款人姓名、不出现任何内网/外网地址。
enum PayDemo {
    static let overview: [String: Any] = [
        "channels": 6,
        "channels_on": 6,
        "channels_online": 4,
        "channels_down": 1,
        "channels_idle": 1,
        "orders": 218,
        "orders_today": 12,
        "paid_today": 9,
        "amount_today": 486.5,
        "amount_total": 12380.0,
        "pending": 3,
        "matches": 341,
        "tickets_open": 1,
    ]

    static let channels: [[String: Any]] = [
        ["id": 9, "no": "F3347", "title": "微信号1 · 主收", "pay_type": "wechat",
         "pay_channel": "微信赞赏码", "bind_type": "微信", "enabled": 1, "online": 1,
         "tier": 1, "tier_name": "优先级", "has_pay_code": true, "intake_mode": "pull",
         "auto_pull": true, "owner_name": "微信号1", "today_amount": 218.0, "yest_amount": 305.0],
        ["id": 10, "no": "F6659", "title": "微信号2 · 备用", "pay_type": "wechat",
         "pay_channel": "微信收款码", "bind_type": "微信", "enabled": 1, "online": 1,
         "tier": 2, "tier_name": "路线2", "has_pay_code": true, "intake_mode": "pull",
         "auto_pull": true, "owner_name": "微信号2", "today_amount": 96.0, "yest_amount": 12.0],
        ["id": 11, "no": "F5669", "title": "支付宝账号1", "pay_type": "alipay",
         "pay_channel": "支付宝收款码", "bind_type": "支付宝", "enabled": 1, "online": 0,
         "tier": 1, "tier_name": "优先级", "has_pay_code": true, "intake_mode": "pull",
         "auto_pull": true, "owner_name": "支付宝账号1", "today_amount": 0.0, "yest_amount": 66.0],
        ["id": 14, "no": "F8080", "title": "支付宝账号2", "pay_type": "alipay",
         "pay_channel": "支付宝收款码", "bind_type": "支付宝", "enabled": 1, "online": 1,
         "tier": 1, "tier_name": "优先级", "has_pay_code": false, "intake_mode": "pull",
         "auto_pull": true, "owner_name": "支付宝账号2", "today_amount": 172.5, "yest_amount": 88.0],
        ["id": 12, "no": "F8585", "title": "微信号3 · 备用", "pay_type": "wechat",
         "pay_channel": "微信赞赏码", "bind_type": "微信", "enabled": 1, "online": 1,
         "tier": 3, "tier_name": "备用", "has_pay_code": true, "intake_mode": "push",
         "auto_pull": false, "owner_name": "微信号3", "today_amount": 0.0, "yest_amount": 0.0],
        ["id": 13, "no": "F8584", "title": "微信号4 · 停用", "pay_type": "wechat",
         "pay_channel": "微信赞赏码", "bind_type": "微信", "enabled": 0, "online": 0,
         "tier": 3, "tier_name": "备用", "has_pay_code": true, "intake_mode": "push",
         "auto_pull": false, "owner_name": "微信号4", "today_amount": 0.0, "yest_amount": 0.0],
    ]

    static let probe: [String: Any] = [
        "ok": true,
        "items": [
            ["id": 9, "no": "F3347", "title": "微信号1 · 主收", "pay_type": "wechat",
             "tier": 1, "tier_name": "优先级", "ok": true, "why": "监听端在线（authorized）"],
            ["id": 10, "no": "F6659", "title": "微信号2 · 备用", "pay_type": "wechat",
             "tier": 2, "tier_name": "路线2", "ok": true, "why": "监听端在线（authorized）"],
            ["id": 11, "no": "F5669", "title": "支付宝账号1", "pay_type": "alipay",
             "tier": 1, "tier_name": "优先级", "ok": false, "why": "监听端被安全校验卡住（要重新扫码）"],
            ["id": 14, "no": "F8080", "title": "支付宝账号2", "pay_type": "alipay",
             "tier": 1, "tier_name": "优先级", "ok": true, "why": "监听端在线（authorized）"],
        ],
        "pick": [
            "wechat": ["channel_no": "F3347", "tier": 1, "tier_name": "优先级",
                       "route": ["#9 F3347 优先级 ✓", "#10 F6659 路线2 未探"]],
            "alipay": ["channel_no": "F8080", "tier": 1, "tier_name": "优先级",
                       "route": ["#11 F5669 优先级 ✗ 被安全校验卡住", "#14 F8080 优先级 ✓"]],
        ],
    ]

    static let orders: [[String: Any]] = [
        ["id": 218, "order_no": "LYPA20261011143012A1B2", "merchant_no": "M20261011001",
         "channel_id": 14, "channel_no": "F8080", "pay_type": "alipay",
         "amount": 45.02, "base_amount": 45.0, "real_amount": 45.02, "status": 1,
         "subject": "零砚素材管理器 · 永久买断", "device_code": "A9B5-E862-5B9C",
         "email": "", "remark_code": "7413", "notify_state": 1, "notify_times": 1,
         "created_at": "2026-10-11 14:30:12", "paid_at": "2026-10-11 14:31:03"],
        ["id": 217, "order_no": "LYPA20261011135544C3D4", "merchant_no": "",
         "channel_id": 9, "channel_no": "F3347", "pay_type": "wechat",
         "amount": 20.01, "base_amount": 20.0, "real_amount": 20.01, "status": 1,
         "subject": "零砚素材管理器 · 年付", "device_code": "3F7C-1D20-88AE",
         "email": "", "remark_code": "2088", "notify_state": 1, "notify_times": 1,
         "created_at": "2026-10-11 13:55:44", "paid_at": "2026-10-11 13:56:20"],
        ["id": 216, "order_no": "LYPA20261011130210E5F6", "merchant_no": "",
         "channel_id": 9, "channel_no": "F3347", "pay_type": "wechat",
         "amount": 5.03, "base_amount": 5.0, "real_amount": 0.0, "status": 0,
         "subject": "零砚素材管理器 · 月付体验", "device_code": "",
         "email": "", "remark_code": "5106", "notify_state": 0, "notify_times": 0,
         "created_at": "2026-10-11 13:02:10", "paid_at": ""],
        ["id": 215, "order_no": "LYPA20261010190233G7H8", "merchant_no": "",
         "channel_id": 14, "channel_no": "F8080", "pay_type": "alipay",
         "amount": 45.04, "base_amount": 45.0, "real_amount": 0.0, "status": 5,
         "subject": "零砚素材管理器 · 永久买断", "device_code": "",
         "email": "", "remark_code": "4402", "notify_state": 0, "notify_times": 0,
         "created_at": "2026-10-10 19:02:33", "paid_at": ""],
        ["id": 214, "order_no": "LYPA20261010181205J9K0", "merchant_no": "",
         "channel_id": 11, "channel_no": "F5669", "pay_type": "alipay",
         "amount": 66.05, "base_amount": 66.0, "real_amount": 0.0, "status": 2,
         "subject": "零砚素材管理器 · 年付（取消）", "device_code": "",
         "email": "", "remark_code": "3317", "notify_state": 0, "notify_times": 0,
         "created_at": "2026-10-10 18:12:05", "paid_at": ""],
    ]

    static let matches: [[String: Any]] = [
        ["id": 341, "channel_id": 14, "account": "支付宝账号2", "amount": 45.02,
         "flow": "2026101122001445", "happen_at": "2026-10-11 14:31:00",
         "remark": "7413", "order_no": "LYPA20261011143012A1B2", "state": "matched",
         "created_at": "2026-10-11 14:31:06"],
        ["id": 340, "channel_id": 9, "account": "微信号1", "amount": 20.01,
         "flow": "420000221020261011", "happen_at": "2026-10-11 13:56:18",
         "remark": "2088", "order_no": "LYPA20261011135544C3D4", "state": "matched",
         "created_at": "2026-10-11 13:56:22"],
        ["id": 339, "channel_id": 9, "account": "微信号1", "amount": 88.0,
         "flow": "420000221020261011X", "happen_at": "2026-10-11 10:12:41",
         "remark": "朋友转账", "order_no": "", "state": "ignored",
         "created_at": "2026-10-11 10:12:45"],
        ["id": 338, "channel_id": 10, "account": "微信号2", "amount": 12.0,
         "flow": "420000221020261010Y", "happen_at": "2026-10-10 21:30:02",
         "remark": "", "order_no": "", "state": "new",
         "created_at": "2026-10-10 21:30:08"],
    ]

    static let finance: [String: Any] = [
        "ok": true,
        "total": 486.5,
        "by_type": ["wechat": 314.0, "alipay": 172.5],
        "daily": [
            ["date": "2026-10-05", "count": 4, "amount": 60.0],
            ["date": "2026-10-06", "count": 2, "amount": 25.0],
            ["date": "2026-10-07", "count": 6, "amount": 90.0],
            ["date": "2026-10-08", "count": 3, "amount": 45.0],
            ["date": "2026-10-09", "count": 5, "amount": 110.0],
            ["date": "2026-10-10", "count": 7, "amount": 156.5],
            ["date": "2026-10-11", "count": 9, "amount": 486.5],
        ],
    ]

    static let notifyLogs: [[String: Any]] = [
        ["id": 512, "order_no": "LYPA20261011143012A1B2",
         "url": "（回调地址已隐藏）", "http_code": 200, "ok": 1,
         "req_body": "order_no=LYPA…&amount=45.02&merchant_no=M20261011001&sign=…",
         "resp_body": "success", "created_at": "2026-10-11 14:31:04"],
        ["id": 511, "order_no": "LYPA20261011135544C3D4",
         "url": "（回调地址已隐藏）", "http_code": 200, "ok": 1,
         "req_body": "order_no=LYPA…&amount=20.01&merchant_no=&sign=…",
         "resp_body": "success", "created_at": "2026-10-11 13:56:21"],
        ["id": 510, "order_no": "LYPA20261010190233G7H8",
         "url": "（回调地址已隐藏）", "http_code": 0, "ok": 2,
         "req_body": "order_no=LYPA…&amount=45.04&merchant_no=&sign=…",
         "resp_body": "连接超时", "created_at": "2026-10-10 19:03:00"],
    ]

    static let notifyInbox: [[String: Any]] = [
        ["id": 33, "order_no": "LYPA20261011143012A1B2", "merchant_no": "M20261011001",
         "amount": 45.02, "sign": "a1b2c3…", "sign_ok": 1,
         "body": "{\"order_no\":\"LYPA…\",\"amount\":\"45.02\",\"sign\":\"a1b2c3…\"}",
         "remote": "127.0.0.1", "created_at": "2026-10-11 14:31:04"],
        ["id": 32, "order_no": "LYPA20261011135544C3D4", "merchant_no": "",
         "amount": 20.01, "sign": "d4e5f6…", "sign_ok": 1,
         "body": "{\"order_no\":\"LYPA…\",\"amount\":\"20.01\",\"sign\":\"d4e5f6…\"}",
         "remote": "127.0.0.1", "created_at": "2026-10-11 13:56:21"],
    ]

    static let users: [[String: Any]] = [
        ["id": 1, "username": "admin", "role": "admin",
         "created_at": "2026-10-01 09:00:00", "last_login": "2026-10-11 14:00:00"],
        ["id": 2, "username": "finance", "role": "admin",
         "created_at": "2026-10-05 11:20:00", "last_login": "2026-10-10 18:40:00"],
    ]

    static let keys: [[String: Any]] = [
        ["id": 1, "name": "素材管理器后端", "key": "LYADMIN-1A2B3C4D5E6F7A8B9C0D1E2F3A4B5C6D",
         "enabled": 1, "created_at": "2026-10-08 10:00:00", "last_used": "2026-10-11 14:31:04"],
        ["id": 2, "name": "测试用（可删）", "key": "LYADMIN-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
         "enabled": 1, "created_at": "2026-10-09 15:00:00", "last_used": ""],
    ]

    static let pools: [[String: Any]] = [
        ["id": 1, "name": "微信轮询池", "pay_type": "wechat", "strategy": "round",
         "channel_ids": "[9, 10, 12]", "enabled": 1, "created_at": "2026-10-09 10:00:00"],
        ["id": 2, "name": "支付宝轮询池", "pay_type": "alipay", "strategy": "round",
         "channel_ids": "[11, 14]", "enabled": 1, "created_at": "2026-10-09 10:05:00"],
    ]

    static let settings: [String: Any] = [
        "site_name": "零砚收款",
        "notify_secret": "（已隐藏）",
        "merchant_notify": "（回调地址已隐藏）",
        "session_secret": "（已隐藏）",
        "order_ttl": "900",
        "rematch_window": "30",
    ]

    static let tickets: [[String: Any]] = [
        ["id": 3, "no": "T20261011120000", "title": "支付宝账号1 需要重新扫码",
         "content": "监听端被安全校验卡住，拉不到账单。", "status": "open", "reply": "",
         "created_at": "2026-10-11 12:00:00", "updated_at": "2026-10-11 12:00:00"],
        ["id": 2, "no": "T20261010150000", "title": "给支付宝账号2 配收款码",
         "content": "账号2 还没传收款码，选路切不过去。", "status": "replied",
         "reply": "收到，稍后上传。", "created_at": "2026-10-10 15:00:00",
         "updated_at": "2026-10-10 16:20:00"],
    ]
}
