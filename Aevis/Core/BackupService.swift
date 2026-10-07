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
/// 联系人（人设）、每个人的聊天记录、记忆、**朋友圈（文字 + 配图）**、情侣空间、**头像**，以及一部分设置。
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
    /// | 1 | 明文 JSON，**不含头像、不含朋友圈配图** |
    /// | 2 | 二进制 plist + 整包加密，**含头像原图 + 朋友圈配图**（2026-10-03） |
    static let format = 2

    /// ⭐ T01 新增：**包内结构版本**（与容器 `format` 分开，各管一摊）。
    ///
    /// | 号 | 变化 |
    /// |---|---|
    /// | 2 | 没有 `deviceId` / `revision`，没有 wallet/diary/todo/playlist 分节 |
    /// | 3 | T01 起：包内多了 `deviceId` / `revision`（版本戳），后续再加若干分节 |
    ///
    /// ⚠️ 恢复端**只认 `<= schema`**：比它新的包读不了（`BackupError.tooNew`）。
    ///    改结构就 +1，别动这条规矩。
    static let schema = 3

    /// 上一次备份的文件名，界面上显示用。
    static let lastBackupKey = "aevis.lastBackupName"

    /// 上一次**自动同步**的时刻（自动那个流程用它做节流）。
    static let lastAutoKey = "aevis.lastAutoSync"

    // MARK: - 两种包（**别混着用**）
    //
    // ⭐ 为什么要有两种（2026-10-03 老板要"每发一句话就同步到网盘"之后加的）：
    //    完整包里带头像原图和朋友圈配图，**是几 MB 级的**（图片按 0 和 1 原样存）。
    //    每说一句话就传一次几 MB ⇒ 手机流量、网盘限流、电池全崩。
    //    而聊天记录本身（纯文字）只有几十 KB。
    //    ⇒ 拆成两种：
    //      · `.live`  实时/退出时用：**只有文字那部分**（联系人/聊天/记忆/情侣空间/设置）
    //      · `.full`  手动备份用：加头像 + 朋友圈配图
    //    ⚠️ `.live` 恢复是**非破坏性**的：包里没有 `avatars` / `momentImages` 那两段，
    //       恢复时自然跳过 ⇒ 不会把本机已有的头像覆盖成空。
    /// ⚠️ 声明成 `String` 的 raw value：包里的 `"kind"` 字段直接用 `rawValue`，
    ///    免得再写一处字符串映射（两处映射迟早会对不上）。
    enum Kind: String {
        case live
        case full
        /// ⭐ T01 新增：**钥匙包**（API Key / 网易云 Cookie）。**默认关**（R-17）——
        ///    只有用户显式勾选才写 `aevis-keys.aevis`。**它不含任何业务 Store**，
        ///    只有一个 `keys` 段（见 `KeyBundle.swift` / 架构 §3.2.3）。
        case keys

        /// 给人看的名字（界面上说"正在同步聊天记录"比"正在同步"清楚）。
        var label: String {
            switch self {
            case .live: return "聊天记录"
            case .full: return "完整备份"
            case .keys: return "钥匙包"
            }
        }
    }

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

    // MARK: - 版本戳（T01）
    //
    // ⭐ `deviceId` / `revision` 是**本机**的同步状态，不是"你们之间的东西"：
    //    跟着包搬到新机上 = 新机冒充旧机 ⇒ 一律存 UserDefaults，且**不进包**
    //    （靠 `excludedPrefixes` 里的 `aevis.device.` 前缀天然挡住）。

    /// 产出方稳定设备 id。首次生成后落盘持久（跨启动不变）。
    ///
    /// ⚠️ 故意用 `aevis.device.` 前缀 ⇒ 被 `excludedPrefixes` 挡在 settings 快照外
    ///    （这个 id **绝不能**跟着包搬到别的设备上）。
    static var deviceId: String {
        let key = "aevis.device.syncId"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    /// 版本戳快照（冲突检测用）：本机单调写入序号 + 本机认可的 remote mtime/size。
    ///
    /// ⚠️ 全用 `aevis.device.` 前缀 ⇒ 不进包、不跨设备。写入（`+1`）由同步逻辑负责
    ///    （见 `AutoSync`）；这里只负责**如实打进包**，让电脑端能做三向判断。
    private static func revisionSnapshot() -> [String: Any] {
        let d = UserDefaults.standard
        return [
            "seq": d.integer(forKey: "aevis.device.syncSeq"),
            "baseMtime": d.integer(forKey: "aevis.device.baseMtime"),
            "baseSize": d.integer(forKey: "aevis.device.baseSize")
        ]
    }

    /// 所有会进包的 Store。
    ///
    /// ⚠️ 钥匙包（`.keys`）**不走这里** —— 它只有一个 `keys` 段（由 `KeyBundle` 管），
    ///    不含任何业务 Store。`makeBackup(kind: .keys)` 会跳过这一整段。
    private static func stores() -> [BackupableStore] {
        [PersonaStore.shared, ChatStore.shared, MemoryStore.shared,
         MomentStore.shared, CoupleStore.shared,
         // ⭐ 2026-10-04：日记 / 待办 / 虚拟银行一起进包 ——
         //    老板明确的「所有的东西都存百度网盘」。
         DiaryStore.shared, TodoStore.shared, WalletStore.shared,
         // ⭐ 2026-10-04：ta 的心情（ta 的心里话）也进包 —— 换设备后心情还在。
         //    `MoodStore.swift` 里已补 `extension MoodStore: BackupableStore`
         //    （`backupName = "mood"`），与 `label()` 的 `case "mood"` 对得上。
         MoodStore.shared,
         // ⭐ 2026-10：ta 的小手机（装了哪些 App + 最近动态）也进包 —— 换设备后还在。
         //    `HerPhoneStore.swift` 里已补 `extension HerPhoneStore: BackupableStore`
         //    （`backupName = "herphone"`），与 `label()` 的 `case "herphone"` 对得上。
         HerPhoneStore.shared,
         // ⭐ 2026-10：真实生活（订单 + 假客服）也进包 —— 换设备后订单还在。
         //    `RealLifeStore.swift` 里已补 `extension RealLifeStore: BackupableStore`
         //    （`backupName = "reallife"`），与 `label()` 的 `case "reallife"` 对得上。
         //    ⚠️ 只备份**订单 + 假客服**，**不含**店 / 商品常量 —— 那些是内置的，
         //       由数据层自己重建（见 `RealLifeStore.Archive`）。
         RealLifeStore.shared,
         // ⭐ 2026-10：群聊也进包 —— 换设备后群还在。
         //    `GroupStore.swift` 里已补 `extension GroupStore: BackupableStore`
         //    （`backupName = "groups"`），与 `label()` 的 `case "groups"` 对得上。
         GroupStore.shared]
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
    /// ⚠️ **必须在主线程调**。它要读各 Store 的 `@Published` 状态和 `ProfileStore` ——
    ///    后台读会让 SwiftUI 收到别的线程的通知，**iOS 26 上会崩（真崩过）**。
    ///
    /// 🔴 这是一个**同步**函数，所以它跑在**调用方的线程**上：
    ///    · 视图里直接调（`ShareCard.runExport`）→ 主线程 ✓
    ///    · 从 `@MainActor` 上下文调 → 主线程 ✓
    ///    真正危险的是"从非主线程的异步函数里调它" —— 见 `backupToPan` 的注释。
    ///
    /// - Parameter kind: `.live` 只装文字那部分（实时同步用，小）；`.full` 连头像和
    ///   朋友圈配图一起装（手动备份用，大）。见 `Kind` 的注释。
    func makeBackup(kind: Kind = .full) throws -> Data {
        var storeObjects: [String: Any] = [:]
        // ⚠️ 钥匙包**不含任何业务 Store** —— 它只有 `keys` 那一段（§3.2.3）。
        //    不加这道判断的话，钥匙包会把整台机器的聊天记录也塞进去。
        if kind != .keys {
            for store in Self.stores() {
                let data = try store.exportBackup()
                // 各 Store 导出的是 **JSON**，所以里面像 `imageData`（聊天图片）这种字段
                // 是 **base64 字符串**，**不是**原生字节 —— 进了下面的 plist 也还是字符串。
                // （base64 是**无损**的 ⇒ 画质不受影响，只是体积多 33%。真要让聊天图片也走
                //   原生字节，得改五个 Store 的序列化协议并双向兼容 —— 本期不做。）
                // ⭐ 真正以**原生字节**进包的是下面单独收的两段：`avatars` 和 `momentImages`。
                storeObjects[store.backupName] = try JSONSerialization.jsonObject(with: data)
            }
        }

        var package: [String: Any] = [
            "app": "Aevis",
            "format": Self.format,
            // ⭐ T01 新增：包内结构版本（2→3）。与 `format`（容器版本）分开。
            "schema": Self.schema,
            // ⭐ 记下这份是轻包还是完整包。恢复时可以照实告诉用户
            //    （"这份是实时同步过来的，没有头像"比"恢复完了"诚实得多）。
            "kind": kind.rawValue,
            // ⭐ T01 新增：产出方稳定设备 id（本机，落盘持久，不进包）。
            "deviceId": Self.deviceId,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "build": (Bundle.main.infoDictionary?["AevisCommit"] as? String) ?? "",
            // ⭐ T01 新增：版本戳（冲突检测用，见架构 §5.2）。本机状态，不跨设备。
            "revision": Self.revisionSnapshot(),
            "stores": storeObjects,
            "settings": try JSONEncoder().encode(settingsSnapshot()).base64EncodedString()
        ]        // ⚠️ `.live` 时这两段**整个不进包**（不是塞空字典）——
        //    这样恢复端"包里没有就跳过"，不会误以为"备份里就是没有头像"而清空本机。
        if kind == .full {
            package["avatars"] = Self.avatarPayload()
            package["momentImages"] = MomentStore.shared.momentImagesForBackup()
        }

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
        // ⭐ T01：**包内结构版本**也要认。比它新 ⇒ 读不了（老 App 见新结构会错位）。
        //    ⚠️ 缺省当成当前版本：老包（schema 2 及以前）根本没有这个字段，不能因此把它拒了。
        let schema = (package["schema"] as? Int) ?? Self.schema
        guard schema <= Self.schema else {
            throw BackupError.tooNew(schema)
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

        // 朋友圈配图同理，等 `moments` 导完再往文件写（按文件名落盘，跟 owner 无关）。
        let imageCount = Self.adoptMomentImages(package["momentImages"] as? [String: Any])
        if imageCount > 0 {
            names.append("朋友圈配图 ×\(imageCount)")
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

        // 告诉用户这份是什么 —— `aevis-live`（实时同步那份）里没有头像和朋友圈配图，
        // 不说明的话他会以为"我的头像丢了"。
        let wasLive = ((package["kind"] as? String) ?? "full") == "live"
        let tail = wasLive ? "（实时同步那份，不含头像和朋友圈配图）" : ""
        return names.isEmpty ? "这个包里没有可恢复的数据。" : "已恢复：" + names.joined(separator: "、") + tail
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

    /// 把朋友圈配图段写回文件。返回成功写回的个数。
    private static func adoptMomentImages(_ raw: [String: Any]?) -> Int {
        guard let raw, !raw.isEmpty else { return 0 }
        var count = 0
        for (name, value) in raw {
            // plist 读回来是 NSData，桥接成 Data 就是原始字节
            guard let bytes = value as? Data, !bytes.isEmpty else { continue }
            if MomentStore.shared.adoptMomentImage(bytes, name: name) { count += 1 }
        }
        return count
    }

    // MARK: - 和网盘打交道

    /// 新备份的扩展名。
    /// ⚠️ **故意不叫 `.json`** —— 它根本不是 JSON（是加密的二进制）。
    ///    写成 `.json` 会让以后排查的人（包括未来的我）第一眼就以为是坏文件。
    static let fileExtension = ".aevis"

    /// 实时同步那份的**固定文件名**（每次覆盖同一个文件）。
    ///
    /// 🔴 为什么实时同步必须用**固定名**而不是像手动备份那样带时间戳：
    ///    每说一句话就传一次，带时间戳的话一天能在网盘上堆出几百个文件
    ///    （老板打开网盘会以为出事了），而且"哪一份是最新的"就没法一眼看出来。
    ///    手动备份仍然带时间戳 —— 那个是要留历史、能挑着恢复的。
    static let liveName = "aevis-live" + fileExtension

    /// 备份并上传，返回文件名。
    ///
    /// - Parameter kind: `.live`（默认）只同步聊天记录那部分，小、快 ——
    ///   **自动那个流程一律用它**；`.full` 是手动「备份到网盘」。
    ///
    /// 🔴🔴 **这里必须是 `@MainActor`**（2026-10-03 补的，以前靠"两个调用方都在
    ///    `Task { @MainActor }` 里"这条**并不成立**的推断撑着）。
    ///
    ///    为什么那条推断不成立：`backupToPan` 是 **`nonisolated` 的 async 函数**，
    ///    Swift 并发规定它**不在调用方的 actor 上跑**，而是跳到通用执行器 ——
    ///    于是 `makeBackup()`（同步函数，跑在调用方线程）**就跑到后台线程去了**，
    ///    而它要读一堆 `@Published` ⇒ SwiftUI 在别的线程收到变更通知 ⇒ iOS 26 硬崩。
    ///    这次是"加自动同步"时顺手查出来的：`BaiduPanCard` 那两条路一直在裸奔。
    ///
    /// ⚠️ 标了 `@MainActor` 也**不会卡住界面**：里面每一句 `await` 都会让出主线程
    ///    （分片上传那几十秒是在 URLSession 的后台队列上跑的）。
    @MainActor
    @discardableResult
    func backupToPan(kind: Kind = .live) async throws -> String {
        let data = try makeBackup(kind: kind)
        let dir = try await BaiduPanClient.shared.ensureBackupDir()
        let name = kind == .live ? Self.liveName : ("aevis-" + Self.stamp() + Self.fileExtension)
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

    /// 该自动恢复哪一份：**实时同步那份和完整备份里，挑更新时间最新的**。
    ///
    /// ⭐ 为什么不是"一律用最新那份完整备份"：老板要的是"换设备就把聊天记录带过来"，
    ///    而聊天记录是**实时**在 `aevis-live` 上更新的 —— 上一份完整备份可能是几天前的。
    ///    挑"最新"能保证拿到的是最近一次说话时的状态。
    /// ⚠️ 拿不到任何一份就返回 `nil`（**别抛错** —— 调用方在启动路径上，
    ///    抛出去会让启动流程难看；"网盘里还没有备份"是正常状态，不是错误）。
    func newestBackup() async -> PanFile? {
        (try? await listBackups())?.first
    }

    /// 哪些文件算备份。
    /// ⚠️ **两种都要认**：老备份是 `.json`（0.0.97 及以前），新的是 `.aevis`。
    ///    只认新的话，用户以前的备份在列表里**直接消失** —— 他会以为数据没了。
    ///    （新版能读老版，反过来不行：老 App 见不到 `.aevis`。）
    static func isBackupName(_ name: String) -> Bool {
        name.hasSuffix(fileExtension) || name.hasSuffix(".json")
    }

    /// 从网盘上某一份备份恢复。
    ///
    /// ⚠️ `@MainActor` 的理由跟 `backupToPan` 一模一样：`restore(from:)` 是同步函数，
    ///    会往各 Store 的 `@Published` 里写；这个 async 函数要是 `nonisolated`，
    ///    那一步就在后台线程上执行 —— 恢复完的瞬间界面就会崩。
    ///    （恢复的破坏性比备份大得多，这里更没得商量。）
    @MainActor
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
        case "couple": return "情侣空间"
        // ⭐ 2026-10-04 新增的三段（日记 / 待办 / 虚拟银行）。
        case "diary": return "日记"
        case "todo": return "一起做的事"
        case "wallet": return "虚拟银行"
        // ⭐ 2026-10-04：ta 的心情（ta 的心里话）。
        case "mood": return "ta 的心情"
        // ⭐ 2026-10：ta 的小手机。
        case "herphone": return "ta 的小手机"
        // ⭐ 2026-10：真实生活（订单 + 假客服）。
        case "reallife": return "真实生活"
        // ⭐ 2026-10：群聊。
        case "groups": return "群聊"
        default: return name
        }
    }
}
