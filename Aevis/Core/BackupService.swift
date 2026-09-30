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
/// 同理还有 `aevis.device.`（设备授权凭证）和 `aevis.account.`（登录会话）——
/// 搬过去新手机就会以为自己已经过审了。见 `excludedPrefixes`。
///
/// 实现上用**黑名单**兜底：任何键名里带 key / cookie / token / secret /
/// password / authorization 的设置项一律不进包。
/// 用黑名单而不是白名单，是因为设置项一直在加 —— 白名单总有一天会漏掉新项，
/// 而漏掉一个**机密**的后果，比漏掉一个普通设置严重得多。
///
/// ## ⚠️⚠️ 恢复期间所有 Store 都「只读不写」
/// 这条是 2026-10-01 修「搬家什么都不搬」时补的：`restore` 走的是
/// 「先导 contacts → `broadcastSwitch` 切人 → 再导 chats/memory/moments」，
/// 而**切人**那一下会触发各 Store 的 `stash()`（把当前内存那份写回字典）。
/// 那一刻 `currentID` 还停在**这台旧机器**上的人，于是旧会话被写了回去，
/// 最后落盘的是旧数据 —— 用户看到的就是「聊天记录一条都没搬过来」。
/// 现在五个 Store 都有 `loading` 标志位，导入期间 `stash()` / `save()` 直接返回。
/// ⚠️ **以后再加「按联系人分开存」的 Store，两件事必须一起做**：
///    ① 在 `PersonaStore.broadcastSwitch` / `remove` 里挂号；
///    ② 自己带 `loading` 标志位，并进 `BackupService.stores()`。
///    漏掉 ① 是「换了人还看着上一个人的东西」，漏掉 ② 是「搬家搬丢」。
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

    /// 这些**前缀**开头的设置项不进包（子串黑名单抓不到的那些）。
    ///
    /// | 键 | 为什么不能搬 |
    /// |---|---|
    /// | `aevis.device.` | 这是**这台设备**过没过审的凭证。跟着包落到新手机上，新手机就会以为自己已经授权过了 —— 旧机被解绑 / 换了账号之后，新机还在裸奔。授权必须在新机上重新走一遍。 |
    /// | `aevis.account.` | 这里放的是账号 token 的到期时刻、打码邮箱这些**跟当前登录会话绑死**的东西。服务器的 token 是发到具体设备上的，搬过去就是一份对不上的残留。 |
    /// | `aevis.lastBackupName` | 网盘上那份备份的文件名，换了机器点「恢复」会指向别人那台机器存的包。 |
    ///
    /// 用前缀而不是逐个键名：以后这些模块再加键，不会漏。
    private static let excludedPrefixes = [
        "aevis.device.",
        "aevis.account.",
        "aevis.lastBackupName"
    ]

    private static func stores() -> [BackupableStore] {
        [PersonaStore.shared, ChatStore.shared, MemoryStore.shared,
         MomentStore.shared, CoupleStore.shared]
    }

    /// 恢复收尾：把「现在看着谁」摆到搬过来的那个 activeID 上。
    ///
    /// 为什么不在导入中间做：导入期间各 Store 是「只写字典、不切当前」的状态，
    /// 切人要等四份数据都落地了才安全 —— 不然切的那一下会把还没导的 Store
    /// 按旧 owner 处理。
    private func syncActive() {
        guard PersonaStore.shared.activeID != nil else { return }
        PersonaStore.shared.resyncToActive()
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

        // ⚠️ 设置放最后：`apply` 会往 UserDefaults 里写一堆键，
        //    先写的话上面那些 Store 恢复完再切一次人，反而可能被脏值带偏。
        if let text = package["settings"] as? String,
           let raw = Data(base64Encoded: text),
           let settings = try? JSONDecoder().decode([String: StoredSetting].self, from: raw) {
            apply(settings)
        }

        // ⚠️ 恢复完**必须把 currentID 摆正**。
        //    搬过来的 `activeID` 由 `PersonaStore.importBackup` 写进通讯录，
        //    但各 Store 的 `currentID`/`owner` 是在导入期间被 `switchTo` 设成
        //    旧机器那个人的（只是被 `loading` 挡住没落盘）—— 不重切一次，
        //    界面上显示的会是旧会话，用户一样会说「没搬过来」。
        syncActive()

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
            guard !Self.excludedPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }

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
