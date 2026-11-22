import Foundation
import SwiftUI
import UIKit

/// 视觉常量（2026-11-22 视觉重做）：与安卓 `V2` 一一对应，改这里就够，别在 View 里写魔法数。
/// 配色：去掉旧紫，改用「高级中性色 + 深墨靛蓝」的克制强调色；明暗两套各自好看。
enum AE {
    // MARK: - 品牌色
    /// 主强调色（文字/图标/描边）：浅色深墨靛蓝 #2F3A56，深色提亮成 #A9B7D8 保证可读（替代旧紫）
    static let accent = Color.adaptive(dark: Color.hex(0xA9B7D8), light: Color.hex(0x2F3A56))
    /// 强调色高光：实色渐变用，固定值，增加质感
    static let accentLift = Color.hex(0x4A5676)
    /// 强调色实底：按钮/头图等白字场景固定深墨靛蓝，避免深色模式糊成一片
    static let accentDeep = Color.hex(0x2F3A56)
    /// 强调色柔和底：卡片内分组 / 未读胶囊 / 头像底
    static let accentSoft = Color.adaptive(dark: Color.hex(0x2B3346), light: Color.hex(0xEAEDF4))
    /// 卡片背景：浅色纯白 / 深色 #1E2028
    static let card = Color.adaptive(dark: Color.hex(0x1E2028), light: .white)
    /// 主文字
    static let textPrimary = Color.adaptive(dark: Color.hex(0xF2F1EC), light: Color.hex(0x1C2231))
    /// 次文字
    static let textSecondary = Color.adaptive(dark: Color.hex(0x9EA2AE), light: Color.hex(0x73798A))
    /// 暖色点缀（只用于未读小圆点等极少处）
    static let warm = Color.hex(0xC9743F)
    /// 柔和阴影
    static let shadowColor = Color.adaptive(dark: Color.black.opacity(0.32), light: Color.black.opacity(0.07))

    // MARK: - 品牌色（登录页专用；对齐官网 icon-new.svg / 安卓 V2 / 小程序）
    // 只新增，不覆盖上面任何常量——ChatView / SettingsView 仍在用旧的墨靛蓝体系。
    /// 奶油底 #FFF8EC（官网 logo 底色）；深色模式落到暖黑，不再是阴冷的深蓝黑
    static let brandCream = Color.adaptive(dark: Color.hex(0x1E1B24), light: Color.hex(0xFFF8EC))
    /// 主柔紫 #9B8AF0（= 安卓 V2.accent / 小程序 btn-primary），按钮与链接统一用它
    static let brandPurple = Color.hex(0x9B8AF0)
    /// 柔紫浅底 #F1EAFF（logo 狗耳填充 / 分组胶囊底）；深色模式降为深紫
    static let brandLilac = Color.adaptive(dark: Color.hex(0x2E2A3E), light: Color.hex(0xF1EAFF))
    /// 暖橙 #FFC6A6（logo 暖色光晕点缀）
    static let brandPeach = Color.hex(0xFFC6A6)
    /// 墨色描边/主文字 #1F2D3F（官网 logo 同色）；深色模式提亮保证可读
    static let brandInk = Color.adaptive(dark: Color.hex(0xF5F2EC), light: Color.hex(0x1F2D3F))
    /// 输入格暖灰底 #F5F0E6（≈ 安卓 V2.wellLight #F2EDE3）
    static let brandWell = Color.adaptive(dark: Color.hex(0x2A2733), light: Color.hex(0xF5F0E6))
    /// 登录页卡片：浅色纯白 / 深色暖黑（比旧的 #1E2028 少一分蓝）
    static let brandCard = Color.adaptive(dark: Color.hex(0x262230), light: .white)

    /// 浅色底 #F7F5F0（更干净的奶油底）
    static let bgLight = Color.hex(0xF7F5F0)
    /// 深色底 #141416
    static let bgDark = Color.hex(0x141416)

    static let cardRadius: CGFloat = 20
    static let bubbleRadius: CGFloat = 16
    static let buttonRadius: CGFloat = 14
    static let sheetRadius: CGFloat = 28

    static let cardPadding: CGFloat = 16
    static let rowHeight: CGFloat = 76
    static let groupGap: CGFloat = 12

    static let title: CGFloat = 17
    static let body: CGFloat = 15
    static let caption: CGFloat = 11
    /// 页面大标题
    static let heroTitle: CGFloat = 34
    /// 分组卡片标题
    static let sectionTitle: CGFloat = 16

    /// 聊天三档字号（与安卓 msgSize 对齐）
    static func chatFont(_ size: Int) -> CGFloat {
        switch size { case 0: return 13.5; case 2: return 17; default: return 15 }
    }
}

extension Color {
    /// `#7664E2` → Color（144 用得多，集中一处）
    static func hex(_ v: UInt32, alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// 明暗自适应：浅色用 light，深色用 dark（跟随系统）
    static func adaptive(dark: Color, light: Color) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// 页面底色（144：浅 #F7F5F0 / 深 #141416）
    static var paper: Color {
        adaptive(dark: Color.hex(0x141416), light: Color.hex(0xF7F5F0))
    }
}

/// 数据模型（2026-11-17，134 骨架）——字段名与安卓**完全对齐**：
/// 网络层用 `role/content/img/w/skip/quote`，本地落盘也一样，方便以后两端互导。

/// 角色。`Codable` 是为了**离线也能看会话列表**：拉不到接口时用本地缓存的
/// 角色列表顶上（`LocalStore.savePersonas/loadPersonas`），不再整屏空白。
struct Persona: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let tagline: String
    let avatar: String

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        self.name = json["name"] as? String ?? "未命名角色"
        self.tagline = (json["tagline"] as? String)
            ?? (json["personality"] as? String)
            ?? (json["persona"] as? String)
            ?? ""
        self.avatar = (json["avatar_url"] as? String) ?? (json["avatar"] as? String) ?? ""
    }

    init(id: String, name: String, tagline: String, avatar: String) {
        self.id = id; self.name = name; self.tagline = tagline; self.avatar = avatar
    }
}

struct Msg: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: String        // user / assistant
    var content: String
    var who: String = ""    // 群聊发言人
    var img: String = ""    // 图片地址（本地或服务端相对路径）
    var skip: Bool = false  // 从上下文移除
    var quote: String = ""

    enum CodingKeys: String, CodingKey {
        case role, content
        case who = "w"
        case img = "i"
        case skip = "x"
        case quote = "q"
    }

    init(role: String, content: String, img: String = "") {
        self.role = role
        self.content = content
        self.img = img
    }
}

/// 本地会话存储：`Documents/convs.json`，`{pid: [Msg]}`。
/// 骨架阶段没有 Core Data，够用且好排查。
enum LocalStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("convs.json")
    }

    static func load(pid: String) -> [Msg] {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: [[String: Any]]],
              let rows = dict[pid] else { return [] }
        return rows.compactMap { row in
            guard let role = row["role"] as? String,
                  let content = row["content"] as? String else { return nil }
            var m = Msg(role: role, content: content)
            m.who = row["w"] as? String ?? ""
            m.img = row["i"] as? String ?? ""
            m.skip = (row["x"] as? String) == "1"
            m.quote = row["q"] as? String ?? ""
            return m
        }
    }

    static func save(pid: String, msgs: [Msg]) {
        var dict = (try? Data(contentsOf: url))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        dict[pid] = msgs.map { m -> [String: Any] in
            var row: [String: Any] = ["role": m.role, "content": m.content, "w": m.who]
            if !m.img.isEmpty { row["i"] = m.img }
            if m.skip { row["x"] = "1" }
            if !m.quote.isEmpty { row["q"] = m.quote }
            return row
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: url)
        }
        // 列表行的时间：记录该会话最后一次写入的时刻（安卓是 convAt）
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "convAt_\(pid)")
    }

    /// 该会话最后活跃时间（没有就 0）。
    static func lastAt(_ pid: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: "convAt_\(pid)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// 「TA 找你了」未读数（主动消息用）。
    static func unread(_ pid: String) -> Int {
        UserDefaults.standard.integer(forKey: "unread_\(pid)")
    }

    static func setUnread(_ pid: String, _ n: Int) {
        UserDefaults.standard.set(n, forKey: "unread_\(pid)")
    }
}
