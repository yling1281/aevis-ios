import Foundation

/// 主 App 和「系统录屏扩展」之间的共享信箱。
///
/// 为什么必须有它：扩展是**独立进程**，它认出来的文字没法直接交给主 App。
/// iOS 给两个进程唯一的合法共享方式就是 **App Group 容器** ——
/// 所以两边都通过这个类读写同一个文件。
///
/// 这个文件**同时编进两个 target**，所以契约只有一份，
/// 不会出现「两边各写一套、对不上」的情况。
///
/// 现实约束（要如实反映到界面上，不能装作没问题）：
/// App Group 的 id 必须**同时**出现在两个 target 的签名权限里。
/// 我们用的是第三方共享证书，那个组的 id 不在自己手里 ——
/// 一旦对不上，容器就是 nil：功能不可用，但**不会崩**，只是要明说。
final class ScreenShareStore {
    static let shared = ScreenShareStore()

    /// 两边必须完全一致 —— 改这里就等于改契约。
    static let appGroupID = "group.com.aevis.ios"

    /// 扩展自己的 bundle id。主 App 要告诉系统「用哪个扩展来录」。
    static let extensionBundleID = "com.aevis.ios.broadcast"

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
    /// 不能用的原因基本只有一个：签名里的「应用程序组」跟 `appGroupID` 对不上。
    var isUsable: Bool {
        containerURL != nil
    }

    /// 不能用的原因，直接给用户看。能用就返回 nil。
    var unavailableReason: String? {
        guard !isUsable else { return nil }
        return "两个进程没能共享到同一个容器。基本可以确定是签名里的「应用程序组」跟 "
            + Self.appGroupID + " 对不上 —— 那组 id 在卖证书的人手里。"
    }

    private var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)
    }

    private func fileURL(_ name: String) -> URL? {
        containerURL?.appendingPathComponent(name, isDirectory: false)
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
