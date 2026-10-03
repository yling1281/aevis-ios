import CryptoKit
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
    case badKey

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
        case .badKey:
            return "这份备份解不开（密钥对不上）。"
        }
    }
}

/// 数据搬家：把整台手机里的 Aevis 打成一个包传到网盘，换设备再拉回来。
///
/// ## 包里装了什么
/// 联系人（人设）、每个人的聊天记录、记忆、朋友圈、情侣空间、**头像**，以及一部分设置。
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
/// ## ⭐ 2026-10-03：包从「明文 JSON」升级成「加密的二进制包」（format 2）
///
/// 老板定的是 **0 和 1 机制**：头像这类图**原始字节上传**，不压缩、不重编码；
/// 整个包加密之后再传网盘。两件事是分开的，**别混为一谈**：
///
/// | 诉求 | 真正的解法 | 为什么 |
/// |---|---|---|
/// | **不压缩画质** | **另存原图**（`avatarOriginalURL`） | 网盘是文件存储，**不会重编码我们的文件**。压画质的是**我们自己**：显示版是 512/JPEG0.88，源文件在那一步就损失了。加密救不回来。 |
/// | **不被网盘扫描/和谐** | **整包 AEAD 加密** | 明文图片传上去，平台会做内容识别；加密之后是随机字节，认不出来，**秒传也失效**（秒传靠内容哈希）。 |
/// | **传一半断掉不留半成品** | **打包成单文件** | 一次上传、原子完成。 |
///
/// ### 两处格式改动（都向后兼容）
/// 1. **序列化**：JSON → **二进制 property list**。
///    因为 `Data` 在 JSON 里只能 base64（膨胀 33%），在 plist 里是**原生字节**。
///    这是"0 和 1"能真正落地的关键。
/// 2. **外层**：加密容器（magic + 版本 + salt + ChaChaPoly）。
///    恢复时先看头：有 magic 就解密，没有就按老格式读 —— **老备份照样能恢复**。
///
/// ### 🔴 这个加密的**边界**（别对外说成"安全加密"）
/// 对称密钥是**编在 App 里的一段固定口令**派生的。它挡住的是：
/// **网盘的内容扫描、平台的和谐、秒传识别、以及"网盘上躺着一份明文聊天记录"**。
/// 它**挡不住**：拿到这个 App 并且愿意逆的人。
/// 要做成"真的只有你能解"，唯一的办法是**让用户设恢复密码**（忘了就真没了）——
/// 那是另一件事，没做。**别把这个说成端到端加密。**
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
    ///
    /// | 号 | 变化 |
    /// |---|---|
    /// | 1 | 明文 JSON，**不含头像** |
    /// | 2 | 二进制 plist + 整包加密，**含头像原图**（2026-10-03） |
    static let format = 2

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

    /// 打一个包出来（纯内存操作，不联网）。产出的是**加密后的二进制**，不是 JSON。
    ///
    /// ⚠️ **必须在主线程调**（两个调用方都是 `Task { @MainActor }`）。
    ///    它要读各 Store 的 `@Published` 状态和 `ProfileStore` ——
    ///    后台读会让 SwiftUI 收到别的线程的通知，**iOS 26 上会崩（真崩过）**。
    func makeBackup() throws -> Data {
        var storeObjects: [String: Any] = [:]
        for store in Self.stores() {
            let data = try store.exportBackup()
            // 转成 JSON 对象再嵌进来。
            // ⚠️ 这里出来的 `imageData` / `voiceData` 是 **NSData**；
            //    在下面那份**二进制 plist** 里它是原生存的（不 base64），正是我们要的。
            storeObjects[store.backupName] = try JSONSerialization.jsonObject(with: data)
        }

        let package: [String: Any] = [
            "app": "Aevis",
            "format": Self.format,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "build": (Bundle.main.infoDictionary?["AevisCommit"] as? String) ?? "",
            "stores": storeObjects,
            "avatars": Self.avatarPayload(),
            "settings": try JSONEncoder().encode(settingsSnapshot()).base64EncodedString()
        ]

        // ⚠️ 一定要用 **PropertyListSerialization 的 `.binary`**，不能再用 JSONSerialization：
        //    JSON 里 `Data` 只能写成 base64 字符串 —— 膨胀 33%，而且"原始字节"这层意思
        //    当场就没了（老板要的 0 和 1 就落不了地）。
        //    plist 里 `Data` 是**原生字节**，一个 bit 都不动。
        let plain = try PropertyListSerialization.data(
            fromPropertyList: package, format: .binary, options: 0)
        return try Self.seal(plain)
    }

    /// 头像段：`"me"` 是我的，`"persona-<uuid>"` 是每个联系人的。
    /// ⚠️ 值是**原始字节**，不做任何编码转换、不重编码、不缩放。
    private static func avatarPayload() -> [String: Data] {
        var out: [String: Data] = [:]
        if let me = ProfileStore.shared.avatarBytesForBackup() {
            out["me"] = me
        }
        for contact in PersonaStore.shared.contacts {
            if let bytes = PersonaStore.shared.avatarBytesForBackup(for: contact.id) {
                out["persona-" + contact.id.uuidString] = bytes
            }
        }
        return out
    }

    /// 从包里恢复（**会覆盖**本机现有数据）。
    @discardableResult
    func restore(from raw: Data) throws -> String {
        // ① 先过加密容器（老备份没有容器，原样返回）
        let data = try Self.open(raw)
        // ② 再解析（新的是二进制 plist，老的是明文 JSON，两种都认）
        guard let package = Self.parsePackage(data) else {
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

        // ⭐ 头像必须在**联系人导完之后**才写回 —— 键是 `persona-<uuid>`，
        //    得先有这些联系人，`adoptAvatar(for:)` 才认得出来是谁的。
        let avatarCount = Self.adoptAvatars(package["avatars"] as? [String: Any])
        if avatarCount > 0 {
            names.append("头像 ×\(avatarCount)")
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

    /// 把头像段写回本机。返回成功写回的个数。
    private static func adoptAvatars(_ raw: [String: Any]?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        var count = 0
        for (key, value) in raw {
            // plist 读回来是 NSData，桥接成 Data 就是原始字节
            guard let bytes = value as? Data, !bytes.isEmpty else { continue }
            if key == "me" {
                ProfileStore.shared.adoptAvatar(from: bytes)
                count += 1
            } else if key.hasPrefix("persona-") {
                let text = String(key.dropFirst("persona-".count))
                guard let id = UUID(uuidString: text) else { continue }
                if PersonaStore.shared.adoptAvatar(bytes, for: id) { count += 1 }
            }
        }
        return count
    }

    // MARK: - 和网盘打交道

    /// 新备份的扩展名。
    /// ⚠️ **故意不叫 `.json`** —— 它根本不是 JSON（是加密的二进制）。
    ///    写成 `.json` 会让以后排查的人（包括未来的我）第一眼就以为是坏文件。
    static let fileExtension = ".aevis"

    /// 备份并上传，返回文件名。
    func backupToPan() async throws -> String {
        let data = try makeBackup()
        let dir = try await BaiduPanClient.shared.ensureBackupDir()
        let name = "aevis-" + Self.stamp() + Self.fileExtension
        try await BaiduPanClient.shared.upload(data, to: dir + "/" + name)
        UserDefaults.standard.set(name, forKey: Self.lastBackupKey)
        return name
    }

    /// 网盘上的备份，新的在前。
    func listBackups() async throws -> [PanFile] {
        let dir = try await BaiduPanClient.shared.ensureBackupDir()
        let files = try await BaiduPanClient.shared.list(dir)
        return files
            .filter { !$0.isDirectory && Self.isBackupName($0.name) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 哪些文件算备份。
    /// ⚠️ **两种都要认**：老备份是 `.json`（0.0.97 及以前），新的是 `.aevis`。
    ///    只认新的话，用户以前的备份在列表里**直接消失** —— 他会以为数据没了。
    ///    （新版能读老版，反过来不行：老 App 见不到 `.aevis`。）
    static func isBackupName(_ name: String) -> Bool {
        name.hasSuffix(fileExtension) || name.hasSuffix(".json")
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

    // MARK: - 加密容器
    //
    // 布局（**长度都是固定的，见下面的常量**）：
    //
    //     ┌──────────┬─────────┬──────────┬───────────┬──────────────────────────┐
    //     │ magic 8B │ ver 1B  │ saltLen 1B│ salt 32B  │ ChaChaPoly combined      │
    //     │AEVISBAK  │  = 2    │  = 32    │ 每次随机   │ nonce12 + 密文 + tag16   │
    //     └──────────┴─────────┴──────────┴───────────┴──────────────────────────┘
    //
    // ⚠️ `saltLen` 存了但固定是 32 —— 留着是为了以后想换长度时不用改 magic。
    // ⚠️ 密文用的是 `SealedBox.combined`，它**自带 nonce**，所以不用另存。

    /// 认自己人的标记。恢复时先看这 8 个字节：
    /// 有 → 新格式（要解密）；没有 → 老格式（明文，直接读）。
    private static let magic = Data("AEVISBAK".utf8)
    private static let containerVersion: UInt8 = 2
    private static let saltLength = 32

    /// 派生密钥用的**固定口令**。
    ///
    /// 🔴 **它不是密钥** —— 编进 App 的东西，谁都能扒出来。见类型注释里的「边界」那段。
    ///    它挡住的是**网盘的扫描 / 和谐 / 秒传识别**，不是"逆了 App 的人"。
    ///
    /// ⚠️ **改这个常量 = 所有老备份当场解不开。** 真要改就得同时留一条"用老口令再试一次"
    ///    的路，否则用户网盘上那些包全废。改之前先想清楚。
    private static let passphrase = "aevis.pan.backup.v2.7f3a91c4e2b8d506"

    private static func key(salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
            salt: salt,
            info: Data("aevis.backup.v2".utf8),
            outputByteCount: 32)
    }

    /// 加密整个包。
    private static func seal(_ plain: Data) throws -> Data {
        // `SymmetricKey(size:)` 出来的就是密码学随机字节，正好当 salt
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let box = try ChaChaPoly.seal(plain, using: key(salt: salt))

        var out = magic
        out.append(containerVersion)
        out.append(UInt8(saltLength))
        out.append(salt)
        out.append(box.combined)
        return out
    }

    /// 如果是加密容器就解开；**不是就原样返回**（老备份走这条路）。
    private static func open(_ raw: Data) throws -> Data {
        guard raw.starts(with: magic) else { return raw }        // 老格式：明文
        let head = magic.count + 2                                // magic + ver + saltLen
        guard raw.count > head + 1 else { throw BackupError.badFormat }

        let version = raw.subdata(in: magic.count..<(magic.count + 1)).first ?? 0
        guard version <= containerVersion else { throw BackupError.tooNew(Int(version)) }

        let len = Int(raw.subdata(in: (magic.count + 1)..<head).first ?? 0)
        guard len > 0, raw.count > head + len else { throw BackupError.badFormat }

        let salt = raw.subdata(in: head..<(head + len))
        let combined = raw.subdata(in: (head + len)..<raw.count)
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(box, using: key(salt: salt))
        } catch {
            // ⚠️ 这里**只可能是密钥不对**（格式我们已经检查过了）。
            //    单独一个错误码，别跟 badFormat 混 —— 用户看到"格式读不出来"
            //    会去重传，而实际是"这份不是你这个密钥做的"。
            throw BackupError.badKey
        }
    }

    /// 解析包体。**新老两种都要认**：
    /// · 新：二进制 property list（`.binary`）
    /// · 老：明文 JSON（0.0.97 及以前）
    private static func parsePackage(_ data: Data) -> [String: Any]? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: Any] {
            return dict
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
