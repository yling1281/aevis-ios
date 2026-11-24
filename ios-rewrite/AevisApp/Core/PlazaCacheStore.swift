import Foundation

/// 广场数据**磁盘硬缓存**（2026-11-24）：冷启动先读本地立刻显示，云端有更新才覆盖。
///
/// 与 ImageCache 同一个思路，只是存 JSON：
/// - 同步 `load()`：Documents/aevis-plaza-cache.json，损坏/缺失返回空，不抛异常；
/// - 异步 `save()`：写临时文件再原子替换，写失败只 NSLog，绝不影响 UI；
/// - `signature` 用规范化拼接 + 简单 FNV-1a 哈希：后端 psquare/list 与 emoji/list
///   **没有 ETag / 304 支持**，所以按内容签名判断是否真变了，没变就不重绘、不写盘；
/// - 云端拉取失败时**保留旧缓存**，由 PlazaView 显示「连不上服务器，显示本地缓存」。
enum PlazaCacheStore {
    struct Payload: Codable {
        var personas: [APIClient.SquarePersona] = []
        var packs: [APIClient.EmojiPack] = []
        var signature: String = ""
        var checkedAt: Double = 0
    }

    private static let file: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("aevis-plaza-cache.json", isDirectory: false)
    }()

    static func load() -> Payload {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return obj
    }

    static func save(_ payload: Payload) {
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("[PlazaCacheStore] save failed: \(error.localizedDescription)")
        }
    }

    /// 内容签名：只覆盖会影响 UI 的字段，顺序固定；哈希只为省空间，不用于安全。
    static func signature(personas: [APIClient.SquarePersona], packs: [APIClient.EmojiPack]) -> String {
        var raw = ""
        for p in personas {
            raw += "p|\(p.id)|\(p.name)|\(p.tagline)|\(p.avatar)|\(p.cover)|\(p.adoptCount)|\(p.isOfficial)\n"
        }
        for p in packs {
            raw += "e|\(p.id)|\(p.name)|\(p.intro)|\(p.cover)|\(p.useCount)|\(p.items.joined(separator: ","))\n"
        }
        var h: UInt64 = 0x811c9dc5
        for b in raw.utf8 {
            h ^= UInt64(b)
            h = h &* 0x01000193
        }
        return String(format: "%016llx", h)
    }
}
