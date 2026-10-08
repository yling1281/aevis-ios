import Foundation

/// 素材条目（/api/v1/materials）
struct MaterialItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: Int { raw.i("id") }
    var filename: String { raw.s("filename") }
    var category: String { raw.s("category") }
    var sizeBytes: Int { raw.i("size_bytes") }
    var tags: [String] { raw.strings("tags") }
    var source: String { raw.s("source") }
    var sourceURL: String { raw.s("source_url") }
    var author: String { raw.s("author") }
    var license: String { raw.s("license") }
    var createdAt: String { raw.s("created_at") }
    var updatedAt: String { raw.s("updated_at") }

    static func == (a: MaterialItem, b: MaterialItem) -> Bool { a.id == b.id && a.filename == b.filename }
    func hash(into h: inout Hasher) { h.combine(id); h.combine(filename) }
}

/// 授权设备（/api/v1/devices）
struct DeviceItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: String { deviceCode }
    var deviceCode: String { raw.s("device_code") }
    var name: String { raw.s("name") }
    var status: String { raw.s("status") }
    var expiresAt: String { raw.s("expires_at") }
    var createdAt: String { raw.s("created_at") }
    var lastSeen: String { raw.s("last_seen") }

    var statusLabel: String {
        switch status {
        case "active", "ok", "normal": return "有效"
        case "expired": return "已过期"
        case "disabled", "banned": return "已停用"
        case "": return "未知"
        default: return status
        }
    }

    static func == (a: DeviceItem, b: DeviceItem) -> Bool { a.deviceCode == b.deviceCode }
    func hash(into h: inout Hasher) { h.combine(deviceCode) }
}

/// 可下载的文件（/api/v1/downloads）
struct DownloadItem: Identifiable, Hashable {
    let raw: [String: Any]

    var id: String { key }
    var key: String { raw.s("key") }
    var title: String { raw.s("title") }
    var note: String { raw.s("note") }
    var name: String { raw.s("name") }
    var size: Int { raw.i("size") }
    var path: String { raw.s("url") }

    static func == (a: DownloadItem, b: DownloadItem) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}
