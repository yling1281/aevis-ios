import Foundation

/// 能被备份的东西，各自实现这三下。
///
/// 为什么不让 BackupService 直接去读它们的存档文件：
/// 各 Store 的存档结构是**私有**的，只有它自己知道怎么序列化；
/// 而且内存里可能还压着没落盘的改动。交给各自导出，才不会漏、不会错位。
protocol BackupableStore {
    /// 备份包里的名字。**定了就别改** —— 改了的话老备份恢复不回来。
    var backupName: String { get }
    /// 导出成 JSON。
    func exportBackup() throws -> Data
    /// 从 JSON 恢复（**会覆盖**当前数据）。
    func importBackup(_ data: Data) throws
}

enum BackupError: LocalizedError {
    case badFormat
    case notOurs
    case tooNew(Int)
    case noBackups

    var errorDescription: String? {
        switch self {
        case .badFormat:
            return "这个文件不是 Aevis 的备份（格式读不出来）。"
        case .notOurs:
            return "这个文件不是 Aevis 的备份。"
        case let .tooNew(version):
            return "这份备份是更新版本的 Aevis 做的（格式 \(version)），当前版本读不了。"
        case .noBackups:
            return "网盘里还没有备份。先去「备份到网盘」传一份。"
        }
    }
}

/// 数据搬家：把整台手机里的 Aevis 打成一个包传到网盘，换设备再拉回来。
///
/// ## 包里装了什么
/// 联系人（人设）、每个人的聊天记录、记忆、朋友圈，以及**一部分设置**。
///
/// ## ⚠️ 包里**没有**什么，以及为什么
/// API Key、网易云 Cookie、百度网盘自己的通行证 —— 这些是**这台设备的钥匙**，
/// 传上云等于把钥匙交出去。搬家要搬的是「你们之间的东西」，不是钥匙。
///
/// 实现上用**黑名单**兜底：任何键名里带 key / cookie / token / secret /
/// password / authorization 的设置项一律不进包。
/// 用黑名单而不是白名单，是因为设置项一直在加 —— 白名单总有一天会漏掉新项，
/// 而漏掉一个**机密**的后果，比漏掉一个普通设置严重得多。
final class BackupService {

    static let shared = BackupService()

    /// 包的格式号。以后改结构就 +1，恢复时能认出是不是太新。
    static let format = 1

    /// 上一次备份的文件名，界面上显示用。
    static let lastBackupKey = "aevis.lastBackupName"

    private init() {}

    // MARK: - 打包

    /// 一个设置项。记了类型，恢复的时候才知道该用什么类型写回去 ——
    /// UserDefaults 的 NSNumber 分不出 Bool 和 Int，不记就只能靠猜。
    private struct StoredSetting: Codable {
        var type: String
        var value: String
    }

    /// 哪些设置项绝不能进包。
    private static let secretHints = [
        "key", "cookie", "token", "secret", "password", "authorization", "apikey"
    ]

    private static func stores() -> [BackupableStore] {
        [PersonaStore.shared, ChatStore.shared, MemoryStore.shared, MomentStore.shared]
    }

    /// 打一个包出来（纯内存操作，不联网）。
    func makeBackup() throws -> Data {
        var storeObjects: [String: Any] = [:]
        for store in Self.stores() {
            let data = try store.exportBackup()
            // 转成 JSON 对象再嵌进来，这样整个包就是一个规规矩矩的 JSON
            storeObjects[store.backupName] = try JSONSerialization.jsonObject(with: data)
        }

        let package: [String: Any] = [
            "app": "Aevis",
            "format": Self.format,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "build": (Bundle.main.infoDictionary?["AevisCommit"] as? String) ?? "",
            "stores": storeObjects,
            "settings": try JSONEncoder().encode(settingsSnapshot()).base64EncodedString()
        ]
        return try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
    }

    /// 从包里恢复（**会覆盖**本机现有数据）。
    @discardableResult
    func restore(from data: Data) throws -> String {
        guard let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BackupError.badFormat
        }
        guard (package["app"] as? String) == "Aevis" else {
            throw BackupError.notOurs
        }
        let version = (package["format"] as? Int) ?? 0
        guard version <= Self.format else {
            throw BackupError.tooNew(version)
        }
        guard let storeObjects = package["stores"] as? [String: Any] else {
            throw BackupError.badFormat
        }

        var names: [String] = []
        for store in Self.stores() {
            guard let object = storeObjects[store.backupName] else { continue }
            let data = try JSONSerialization.data(withJSONObject: object)
            try store.importBackup(data)
            names.append(Self.label(store.backupName))
        }

        if let text = package["settings"] as? String,
           let raw = Data(base64Encoded: text),
           let settings = try? JSONDecoder().decode([String: StoredSetting].self, from: raw) {
            apply(settings)
        }

        return names.isEmpty ? "这个包里没有可恢复的数据。" : "已恢复：" + names.joined(separator: "、")
    }

    // MARK: - 和网盘打交道

    /// 备份并上传，返回文件名。
    func backupToPan() async throws -> String {
        let data = try makeBackup()
        let dir = try await BaiduPanClient.shared.ensureBackupDir()
        let name = "aevis-" + Self.stamp() + ".json"
        try await BaiduPanClient.shared.upload(data, to: dir + "/" + name)
        UserDefaults.standard.set(name, forKey: Self.lastBackupKey)
        return name
    }

    /// 网盘上的备份，新的在前。
    func listBackups() async throws -> [PanFile] {
        let dir = try await BaiduPanClient.shared.ensureBackupDir()
        let files = try await BaiduPanClient.shared.list(dir)
        return files
            .filter { !$0.isDirectory && $0.name.hasSuffix(".json") }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 从网盘上某一份备份恢复。
    func restoreFromPan(fsID: Int64) async throws -> String {
        let data = try await BaiduPanClient.shared.download(fsID: fsID)
        return try restore(from: data)
    }

    var lastBackupName: String {
        UserDefaults.standard.string(forKey: Self.lastBackupKey) ?? ""
    }

    // MARK: - 设置快照

    private func settingsSnapshot() -> [String: StoredSetting] {
        var out: [String: StoredSetting] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
            guard key.hasPrefix("aevis.") else { continue }
            let lowered = key.lowercased()
            guard !Self.secretHints.contains(where: { lowered.contains($0) }) else { continue }

            if let text = value as? String {
                out[key] = StoredSetting(type: "s", value: text)
            } else if let number = value as? NSNumber {
                // NSNumber 自己分不出 Bool 和 Int，看 objCType：'c' 就是 Bool
                let isBool = String(cString: number.objCType) == "c"
                out[key] = StoredSetting(
                    type: isBool ? "b" : "d",
                    value: isBool ? (number.boolValue ? "1" : "0") : number.stringValue
                )
            }
        }
        return out
    }

    private func apply(_ settings: [String: StoredSetting]) {
        let defaults = UserDefaults.standard
        for (key, item) in settings {
            switch item.type {
            case "s":
                defaults.set(item.value, forKey: key)
            case "b":
                defaults.set(item.value == "1", forKey: key)
            case "d":
                if let number = Double(item.value) { defaults.set(number, forKey: key) }
            default:
                break
            }
        }
    }

    // MARK: - 零件

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    /// 把内部的键名翻成人话，恢复完告诉用户恢复了什么。
    private static func label(_ name: String) -> String {
        switch name {
        case "contacts": return "联系人"
        case "chats": return "聊天记录"
        case "memory": return "记忆"
        case "moments": return "朋友圈"
        default: return name
        }
    }
}
