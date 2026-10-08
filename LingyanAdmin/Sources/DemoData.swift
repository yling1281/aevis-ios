import Foundation

/// `-demo` 启动参数下的假数据。
///
/// 为什么要它：CI 里的**截图自检**要能拍到每一页，但截图时不能带着真的 API Key
/// （仓库是公开的，Key 写进 workflow 就等于公开泄露）。所以给一个纯本地假数据模式，
/// 界面结构照常渲染，一个网络请求都不发。
///
/// ⚠️ 它必须能**绕过"未配置 Key 就先显示设置页"那道门**，
///    否则所有截图都会是同一屏设置页（编译一路绿，图全废）。
enum DemoData {
    static var me: [String: Any] {
        ["ok": true, "name": "演示 Key（零砚）", "scopes": ["card", "read"],
         "created_at": "2026-10-08T12:00:00", "note": "截图自检用，不连服务器"]
    }

    static var stats: [String: Any] {
        ["ok": true,
         "stats": ["users": 11, "materials": 276, "devices": 2,
                   "cards": ["unused": 37, "bound": 2, "disabled": 0, "today": 5]],
         "server_time": "2026-10-08T18:40:00"]
    }

    static var materials: [String: Any] {
        let rows: [[String: Any]] = [
            ["id": 276, "filename": "角色_小狐狸三视图.fla", "category": "角色", "tags": ["矢量", "三视图"],
             "size_bytes": 3_145_728, "source": "站酷", "source_url": "https://www.zcool.com.cn/",
             "author": "零砚", "license": "CC0", "created_at": "2026-10-07T21:10:00", "updated_at": "2026-10-08T09:00:00"],
            ["id": 275, "filename": "场景_森林清晨.fla", "category": "场景", "tags": ["背景"],
             "size_bytes": 8_388_608, "source": "自己画", "source_url": "", "author": "零砚",
             "license": "", "created_at": "2026-10-06T18:02:00", "updated_at": "2026-10-06T18:02:00"],
            ["id": 274, "filename": "动作_奔跑循环8帧.fla", "category": "动作", "tags": ["逐帧"],
             "size_bytes": 16_777_216, "source": "磁力素材网", "source_url": "https://www.cilisucai.com/",
             "author": "", "license": "", "created_at": "2026-10-05T11:20:00", "updated_at": "2026-10-05T11:20:00"],
            ["id": 273, "filename": "特效_粒子爆裂.fla", "category": "特效", "tags": ["粒子", "合成"],
             "size_bytes": 2_097_152, "source": "B站", "source_url": "", "author": "某某",
             "license": "署名", "created_at": "2026-10-04T09:15:00", "updated_at": "2026-10-04T09:15:00"],
            ["id": 272, "filename": "UI_按钮弹跳.fla", "category": "UI", "tags": [],
             "size_bytes": 524_288, "source": "", "source_url": "", "author": "",
             "license": "", "created_at": "2026-10-03T20:41:00", "updated_at": "2026-10-03T20:41:00"],
            ["id": 271, "filename": "表情包_柴犬18连.fla", "category": "表情包", "tags": ["表情"],
             "size_bytes": 4_194_304, "source": "微信群", "source_url": "", "author": "",
             "license": "", "created_at": "2026-10-02T13:33:00", "updated_at": "2026-10-02T13:33:00"],
        ]
        return ["ok": true, "total": 276, "limit": 200, "offset": 0, "items": rows]
    }

    static var devices: [String: Any] {
        let rows: [[String: Any]] = [
            ["device_code": "A1B2-C3D4-E5F6-7788", "name": "零砚的工作机", "status": "active",
             "expires_at": "2027-10-08", "created_at": "2026-09-18T10:00:00", "last_seen": "2026-10-08T18:31:00"],
            ["device_code": "9F8E-7D6C-5B4A-3210", "name": "备用机", "status": "active",
             "expires_at": "2027-01-02", "created_at": "2026-10-01T09:20:00", "last_seen": "2026-10-07T22:05:00"],
        ]
        return ["ok": true, "total": rows.count, "items": rows]
    }

    static var downloads: [String: Any] {
        let rows: [[String: Any]] = [
            ["key": "plugin", "title": "零砚 Animate 插件（二合一）", "note": "一次装好两个面板：素材库、配音助手",
             "name": "零砚Animate插件安装程序.exe", "size": 7_564_218, "url": "/api/v1/download/plugin"],
            ["key": "desktop", "title": "桌面完整版", "note": "功能最全的 Windows 客户端",
             "name": "零砚素材管理器-单机版.exe", "size": 211_374_852, "url": "/api/v1/download/desktop"],
            ["key": "web", "title": "网页版客户端", "note": "轻量 exe，双击起本地服务并打开浏览器",
             "name": "零砚素材管理器-网页版.exe", "size": 55_191_449, "url": "/api/v1/download/web"],
        ]
        return ["ok": true, "rows": rows]
    }
}
