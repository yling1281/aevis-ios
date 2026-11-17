import Foundation
import SwiftUI
import UIKit

/// 视觉常量（2026-11-17，140）：与安卓 `V2` 一一对应，改这里就够，别在 View 里写魔法数。
enum AE {
    /// 主色 #7664E2
    static let accent = Color(red: 0x76 / 255.0, green: 0x64 / 255.0, blue: 0xE2 / 255.0)
    /// 浅色底 #F6F3EC
    static let bgLight = Color(red: 0xF6 / 255.0, green: 0xF3 / 255.0, blue: 0xEC / 255.0)
    /// 深色底（与安卓 bgDark 一致）
    static let bgDark = Color(red: 0x16 / 255.0, green: 0x15 / 255.0, blue: 0x1A / 255.0)

    static let cardRadius: CGFloat = 18
    static let bubbleRadius: CGFloat = 14
    static let buttonRadius: CGFloat = 12
    static let sheetRadius: CGFloat = 24

    static let cardPadding: CGFloat = 16
    static let rowHeight: CGFloat = 56
    static let groupGap: CGFloat = 12

    static let title: CGFloat = 17
    static let body: CGFloat = 15
    static let caption: CGFloat = 11

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

struct Persona: Identifiable, Equatable {
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
