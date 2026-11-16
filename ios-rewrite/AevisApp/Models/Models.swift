import Foundation

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
    }
}
