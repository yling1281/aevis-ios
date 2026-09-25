import Foundation

/// 主 App 和「系统录屏扩展」之间的共享信箱。
///
/// 为什么必须有它：扩展是**独立进程**，它认出来的文字没法直接交给主 App。
/// iOS 给两个进程唯一的合法共享方式就是 **App Group 容器** ——
/// 所以两边都通过这个类读写同一个文件。
///
/// 这个文件**同时编进两个 target**，所以契约只有一份，
/// 不会出现「两边各写一套、对不上」的情况。
final class ScreenShareStore {
    static let shared = ScreenShareStore()

    // MARK: - 应用组怎么定

    /// 我们自己写在描述文件里的那个（首选）。
    static let preferredAppGroup = "group.com.aevis.ios"

    /// 扩展自己的 bundle id。主 App 要告诉系统「用哪个扩展来录」。
    static let extensionBundleID = "com.aevis.ios.broadcast"

    /// **实际用得上的那个**应用组。见 `resolveGroupID()`。
    ///
    /// 为什么不直接用 `preferredAppGroup`：
    /// 我们的 IPA 是在手机上用第三方工具重签的，那份描述文件里的
    /// 「应用程序组」很可能是**卖证书那个人的 id**，而不是我们自己写的那个。
    /// 写死的话容器直接是 nil —— 录屏就白装了，而界面上只会表现成
    /// 「扩展没反应」，极难查。所以这里会退一步，从本进程的权限清单里
    /// 挑一个真能用的。
    static let appGroupID = resolveGroupID()

    private static let securityPath =
        "/System/Library/Frameworks/Security.framework/Security"

    // MARK: - 数据

    /// 她「看到」的一条。
    struct Entry: Codable {
        var text: String
        var at: Date
    }

    /// 扩展当前的状态。
    struct State {
        var running = false
        var frames = 0
        var hits = 0
        var updatedAt: Date?
    }

    private let entriesFile = "screen-observations.json"
    private let stateFile = "screen-state.json"
    private let maxEntries = 40
    /// 扩展写完、主 App 读 —— 两个进程，得自己加锁。
    private let lock = NSLock()

    private init() {}

    // MARK: - 容器

    /// 共享容器是不是真的能用。
    var isUsable: Bool {
        containerURL != nil
    }

    /// 不能用的原因，直接给用户看。能用就返回 nil。
    var unavailableReason: String? {
        guard !isUsable else { return nil }
        let tried = Self.candidates().joined(separator: "、")
        return "两个进程没能共享到同一个容器 —— 签名里的「应用程序组」一个都没对上。"
            + "试过：\(tried)。那组 id 在卖证书的人手里，重签的时候如果没带上，"
            + "系统录屏就只能录、文字传不回来。"
    }

    /// 给诊断用：实际用了哪个组、试过哪些。
    static var diagnosticLine: String {
        let tried = candidates()
        if tried.count <= 1 {
            return "应用组：\(appGroupID)"
        }
        return "应用组：\(appGroupID)（在本机权限里找到 \(tried.count) 个，按可用性试）"
    }

    private var containerURL: URL? {
        Self.container(for: Self.appGroupID)
    }

    private func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 挑一个能用的应用组

    /// 按「先自己写的、再本机权限里有的」顺序，挑第一个真能用的。
    ///
    /// 两边（主 App 和扩展）都是同一个描述文件签的，**读到的清单是同一份**，
    /// 所以各自独立地挑，也会挑中同一个 —— 不需要额外约定。
    private static func resolveGroupID() -> String {
        for candidate in candidates() where container(for: candidate) != nil {
            return candidate
        }
        // 一个都用不了：返回首选那个，让上层照常报「容器不可用」
        return preferredAppGroup
    }

    /// 候选列表：自己写的排最前，然后是权限里那些「看起来像 Aevis 的」，
    /// 最后才是剩下的。顺序稳定，所以两个进程会选到同一个。
    private static func candidates() -> [String] {
        var ordered: [String] = [preferredAppGroup]
        for group in ownEntitlementGroups() where !ordered.contains(group) {
            ordered.append(group)
        }
        let ranked = ordered.enumerated().sorted { left, right in
            let a = rank(left.element)
            let b = rank(right.element)
            if a != b { return a < b }
            return left.offset < right.offset
        }
        return ranked.map { $0.element }
    }

    private static func rank(_ group: String) -> Int {
        let lowered = group.lowercased()
        if lowered == preferredAppGroup.lowercased() { return 0 }
        if lowered.contains("aevis") { return 1 }
        return 2
    }

    private static func container(for group: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// 读**本进程自己**的权限清单里声明的应用组。
    ///
    /// ⚠️ 这里用的是私有 API（`SecTaskCopyValueForEntitlement`），
    /// 所以整段做成「**找不到就当没有**」：
    /// 用 `dlsym` 现查符号，查不到就返回空表，绝不崩。
    /// 项目一贯的路子就是「私有 API 作兜底 + 运行时探测 + 失败静默降级」。
    private static func ownEntitlementGroups() -> [String] {
        guard let handle = dlopen(securityPath, RTLD_LAZY) else { return [] }
        defer { dlclose(handle) }

        let createSymbol: UnsafeMutableRawPointer? = dlsym(handle, "SecTaskCreateFromSelf")
        let copySymbol: UnsafeMutableRawPointer? =
            dlsym(handle, "SecTaskCopyValueForEntitlement")
        // 显式重绑定，不写简写 —— 老一点的 Swift 版本也编得过
        guard let createSymbol = createSymbol, let copySymbol = copySymbol else { return [] }

        typealias CreateFn = @convention(c) (CFAllocator?) -> CFTypeRef?
        // error 参数我们永远传 nil，用裸指针接，省得纠结它的具体类型
        typealias CopyFn = @convention(c) (CFTypeRef?, CFString, UnsafeMutableRawPointer?) -> CFTypeRef?
        let createTask = unsafeBitCast(createSymbol, to: CreateFn.self)
        let copyValue = unsafeBitCast(copySymbol, to: CopyFn.self)

        // ⚠️ 这里**不能** CFRelease —— 在 Swift 里那两个函数标着
        // 「unavailable: Core Foundation objects are automatically memory managed」，
        // 写了就是**编译错误**（我在这里栽过一次，本地没拦住、CI 才报出来）。
        // 这段每次启动最多跑一次，就算真漏掉一个小对象也无所谓。
        guard let task = createTask(kCFAllocatorDefault) else { return [] }

        let key = "com.apple.security.application-groups" as CFString
        guard let value = copyValue(task, key, nil) else { return [] }

        if let list = value as? NSArray {
            return list.compactMap { $0 as? String }
        }
        if let single = value as? String {
            return [single]
        }
        return []
    }

    // MARK: - 写（扩展那边用）

    /// 记一条。返回有没有真的写进去。
    @discardableResult
    func append(_ text: String, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(entriesFile) else { return false }
        var list = decodeEntries()
        list.insert(Entry(text: text, at: date), at: 0)
        if list.count > maxEntries {
            list.removeLast(list.count - maxEntries)
        }
        return write(list, to: url)
    }

    /// 扩展上报「在录 / 停了」，顺带带上它的统计。
    func markRunning(_ running: Bool, frames: Int = 0, hits: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL(stateFile) else { return }
        let object: [String: Any] = [
            "running": running,
            "frames": frames,
            "hits": hits,
            "updatedAt": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 读（主 App 那边用）

    func readState() -> State {
        lock.lock()
        defer { lock.unlock() }
        var out = State()
        guard let url = fileURL(stateFile),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return out }
        out.running = (object["running"] as? Bool) ?? false
        out.frames = (object["frames"] as? Int) ?? 0
        out.hits = (object["hits"] as? Int) ?? 0
        if let stamp = object["updatedAt"] as? Double {
            out.updatedAt = Date(timeIntervalSince1970: stamp)
        }
        return out
    }

    func readEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return decodeEntries()
    }

    /// 扩展是不是**现在**还在录。
    ///
    /// 只看 running 不够 —— 扩展被系统杀掉时没机会上报「我停了」，
    /// 那个标记会一直挂着。所以再要求它最近更新过。
    func isLive(within seconds: TimeInterval = 40) -> Bool {
        let state = readState()
        guard state.running, let updatedAt = state.updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) <= seconds
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        for name in [entriesFile, stateFile] {
            guard let url = fileURL(name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 零件

    private func decodeEntries() -> [Entry] {
        guard let url = fileURL(entriesFile),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let list = try? decoder.decode([Entry].self, from: data) else { return [] }
        return list
    }

    private func write(_ list: [Entry], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(list) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 两边共用的文字处理
    //
    // 放在这里而不是各写一份：扩展认字、主 App 显示，用的必须是同一套规则，
    // 否则「怎么算同一屏」两边判断不一致，会重复上报或者漏掉。

    /// 把一屏散乱的文字压成一句像话的东西。
    static func condense(_ raw: String) -> String {
        raw.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 2 }
            .prefix(12)
            .joined(separator: " / ")
    }

    /// 0~1，越大越像。用「两个字一组」的重合度粗略估算 ——
    /// 不需要多准，只要能挡住「同一页反复上报」就够了。
    static func similarity(_ left: String, _ right: String) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let a = Set(bigrams(left))
        let b = Set(bigrams(right))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    /// 这一屏跟上一屏比，算不算新内容。
    static func isFresh(_ text: String, comparedTo previous: String) -> Bool {
        guard text.count >= 4 else { return false }
        guard text != previous else { return false }
        return similarity(text, previous) <= 0.8
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return characters.map(String.init) }
        var out: [String] = []
        for index in 0..<(characters.count - 1) {
            out.append(String(characters[index...(index + 1)]))
        }
        return out
    }
}
