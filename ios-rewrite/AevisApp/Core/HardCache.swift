import Foundation
import UIKit

/// 统一磁盘硬缓存层（2.8，用户诉求：「所有东西都要硬缓存，不点开也要有」）。
///
/// 与旧的 `PlazaCacheStore` 只服务广场不同，这里是**全 App 唯一入口**：
/// - JSON：`HardCache.saveJSON / cachedJSON`，key → Documents/aevis-hardcache-vN/<hash>.json；
/// - 图片：`HardCache.image(url:scope:) / refreshImage(url:scope:)`，转给 `ImageCache`（ETag 条件请求）；
/// - 版本签名：`schemaVersion` 参与目录名与文件名，改结构时加一，旧缓存整批自动失效；
/// - 作用域 `scope`：`uid` / `persona.id` / `pack.id`，保证头像、用户态数据不串人；
/// - 过期清理：`cleanup(maxAge:)` 只删"很久没碰过"的文件，不碰新鲜的缓存。
///
/// 读永远同步、永远不抛；写失败只 NSLog。缓存是加速与离线兜底，**不是数据来源**，
/// 所以任何写入失败都不能让界面白屏。
enum HardCache {
    /// 缓存结构版本。字段语义变了就 +1：旧目录不再被读，也不需要迁移脚本。
    static let schemaVersion = 2

    /// 稳定 key。每一类接口一个，避免各处手写字符串拼错。
    enum Key: String {
        case appConfig
        case lineConfig
        case growthConfig
        case growthActivities
        case squarePersonas
        case emojiPacks
        case pointPackages
        case shopProducts
        case quotaState
        case pointsHome
        case memberState
        case usesBalance
        case payMethods
        case payOrder
        case chatLogs
    }

    // MARK: - 任意 JSON 的 Codable 容器

    /// 服务端返回的是 `[String: Any]`，不是强类型模型。这里做一层无损中转，
    /// 使现有 APIClient 的解析函数可以原样吃缓存数据，不用给每个 DTO 补 Codable。
    enum AnyJSON: Codable {
        case null
        case bool(Bool)
        case number(Double)
        case string(String)
        case array([AnyJSON])
        case object([String: AnyJSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let a = try? c.decode([AnyJSON].self) {
                self = .array(a)
            } else if let o = try? c.decode([String: AnyJSON].self) {
                self = .object(o)
            } else {
                self = .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .number(let n): try c.encode(n)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }

        /// 还原成 Foundation 对象。`NSNumber` 会被 `as? NSNumber` 接住，
        /// 所以 APIClient 里既有的整数解析一行都不用改。
        var any: Any {
            switch self {
            case .null: return NSNull()
            case .bool(let b): return b
            case .number(let n): return NSNumber(value: n)
            case .string(let s): return s
            case .array(let a): return a.map { $0.any }
            case .object(let o):
                var out: [String: Any] = [:]
                for (k, v) in o { out[k] = v.any }
                return out
            }
        }

        /// JSONSerialization 的结果 → AnyJSON。布尔必须用 CFBoolean 判定，
        /// 直接 `as? Bool` 会把 NSNumber(1) 也当成 true。
        static func from(_ value: Any) -> AnyJSON {
            if value is NSNull { return .null }
            if let n = value as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
                return .number(n.doubleValue)
            }
            if let b = value as? Bool { return .bool(b) }
            if let s = value as? String { return .string(s) }
            if let a = value as? [Any] { return .array(a.map { from($0) }) }
            if let o = value as? [String: Any] {
                var out: [String: AnyJSON] = [:]
                for (k, v) in o { out[k] = from(v) }
                return .object(out)
            }
            return .null
        }
    }

    /// 落盘格式：版本 + 写入时刻 + 原始内容。
    private struct Envelope: Codable {
        var version: Int = HardCache.schemaVersion
        var savedAt: Double = 0
        var payload: AnyJSON = .null
    }

    // MARK: - 路径

    private static let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("aevis-hardcache-v\(schemaVersion)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private static func stem(_ key: Key, scope: String) -> String {
        let raw = "\(schemaVersion)|\(scope)|\(key.rawValue)"
        var h: UInt64 = 0x811c9dc5
        for b in raw.utf8 {
            h ^= UInt64(b)
            h = h &* 0x01000193
        }
        return String(format: "%016llx", h)
    }

    private static func fileURL(_ key: Key, scope: String) -> URL {
        dir.appendingPathComponent(stem(key, scope: scope) + ".json", isDirectory: false)
    }

    // MARK: - JSON 读写

    /// 同步读。缺失 / 损坏 / 版本不符都返回 nil，永不抛。
    static func cachedJSON(_ key: Key, scope: String = "") -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL(key, scope: scope)),
              let box = try? JSONDecoder().decode(Envelope.self, from: data),
              box.version == schemaVersion,
              let obj = box.payload.any as? [String: Any] else { return nil }
        return obj
    }

    /// 原子写：临时文件 + replace，写一半崩了也不会留下半个 JSON。
    static func saveJSON(_ key: Key, _ value: [String: Any], scope: String = "") {
        let box = Envelope(version: schemaVersion,
                           savedAt: Date().timeIntervalSince1970,
                           payload: AnyJSON.from(value))
        do {
            let data = try JSONEncoder().encode(box)
            try data.write(to: fileURL(key, scope: scope), options: .atomic)
        } catch {
            NSLog("[HardCache] save \(key.rawValue) failed: \(error.localizedDescription)")
        }
    }

    /// 缓存是否还在 TTL 内。用于「新鲜就别打网」；过期不等于删除，
    /// stale-while-revalidate 仍可用旧值先渲染。
    static func isFresh(_ key: Key, scope: String = "", ttl: TimeInterval) -> Bool {
        guard let data = try? Data(contentsOf: fileURL(key, scope: scope)),
              let box = try? JSONDecoder().decode(Envelope.self, from: data),
              box.version == schemaVersion else { return false }
        return Date().timeIntervalSince1970 - box.savedAt < ttl
    }

    /// 缓存最后写入时刻（没有缓存返回 0），给界面显示「更新于 X」用。
    static func savedAt(_ key: Key, scope: String = "") -> Double {
        guard let data = try? Data(contentsOf: fileURL(key, scope: scope)),
              let box = try? JSONDecoder().decode(Envelope.self, from: data) else { return 0 }
        return box.savedAt
    }

    static func remove(_ key: Key, scope: String = "") {
        try? FileManager.default.removeItem(at: fileURL(key, scope: scope))
    }

    /// 清掉久未使用的文件。默认 30 天；只按 mtime 判断，不按业务字段。
    /// 建议在登录预加载后调用一次，不在界面渲染路径上跑。
    static func cleanup(maxAge: TimeInterval = 30 * 24 * 3600) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let cutoff = Date().timeIntervalSince1970 - maxAge
        for name in names {
            let url = dir.appendingPathComponent(name, isDirectory: false)
            guard let attr = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = (attr[.modificationDate] as? Date)?.timeIntervalSince1970 else { continue }
            if mtime < cutoff { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - 图片（统一入口，实际带 ETag 的实现在 ImageCache）

    /// 同步读图：有就立刻出图，没有返回 nil（调用方显示占位，不转圈）。
    static func image(url: URL, scope: String = "") -> UIImage? {
        ImageCache.shared.cached(url, scope: scope)
    }

    /// 后台条件校验：304 / 未到间隔 / 断网都返回 nil，保留磁盘旧图。
    static func refreshImage(url: URL, scope: String = "") async -> UIImage? {
        await ImageCache.shared.revalidate(url, scope: scope)
    }
}
