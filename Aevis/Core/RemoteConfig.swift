import Foundation

/// 远端配置 —— **不出新包也能改开关 / 改参数**。
///
/// ## 为什么是它，不是「App 自升级」
/// iOS 的 App **不能给自己装 IPA**（系统的硬限制），所以字面意义的「在线升级」
/// 做不到。能落地的就是这一层：把一些开关放到后端，App 开机 / 回前台拉一次 ——
/// 想改行为直接改后端，**不用重出包**。
///
/// ## 两条硬要求
/// 1. **宽容解析**：值可能是 `1` / `true` / `yes` / `on`（开），
///    也可能是 `0` / `false` / `no` / `off`（关），还可能是数字。
/// 2. **fail-open**：拉不到、解析不了 → 一律返回调用方给的 `default`。
///    **绝不能因为拉不到配置就把功能关掉** —— 谁知道以后会不会有人
///    拿它当 kill switch 用错。
final class RemoteConfig {
    static let shared = RemoteConfig()

    /// 缓存拉到的配置（跟机器走）。网络失败时读它，保证「至少不退化」。
    private static let cacheKey = "aevis.remoteConfig.cache"

    /// 值一律当**字符串**存 / 读（后端也是这么存的，两端对齐）。
    private var table: [String: String] = [:]
    private let lock = NSLock()

    private init() {
        // 先用上次那份缓存垫上，别等网络 —— 开机第一帧就能读。
        let cached = UserDefaults.standard.dictionary(forKey: Self.cacheKey) as? [String: String]
        table = cached ?? [:]
    }

    // MARK: - 拉取

    /// 拉一次远端配置。**不抛异常、不阻塞启动** —— 失败就安静用缓存。
    func refresh() async {
        // 基址**按优先级挨个试**（别只试一条，栽过）：
        //   ① `AccountEndpoint.resolved` —— 上次探到能通的那条线（最快，省一次 404）
        //   ② `AevisHosts.accountCandidates` —— 编译进去的两条线（**锚点**）
        // ⚠️ 为什么第 ② 条最关键：这份配置的用途之一就是**改接口地址本身**。
        //    如果只认①，一旦那条被改坏/下线，就永远拉不到新配置、也就永远纠不回来
        //    （能拉配置的那条路必须先活着）。编译进去的地址**这一版包里不会变**，
        //    所以它才是那个"无论如何都试一下"的锚点。
        // ⚠️ 这里**不能**读远端配置里那个 `accountBase` 覆盖值本身 —— 它就在这份配置里，
        //    读了是先有鸡还是先有蛋（这正是要留第 ② 条锚点的原因）。
        // ⚠️ **本文件必须自包含**（只依赖 Foundation + `AevisHosts` + `AccountEndpoint`）：
        //    `AevisAdmin` 那个 target 也编它（`AccountEndpoint` 要调 `remoteOverride()`），
        //    而管理端里**没有** `AppSettings` —— 2026-10-02 就因为这里读了一下
        //    `AppSettings.shared.accountServerURL`，管理端那轮 CI 直接编不过。
        //    **别**想着把 `AppSettings` 挪进管理端：那会把主 App 的设置体系整块拖进去。
        var bases: [String] = []
        if let resolved = AccountEndpoint.resolved, !resolved.isEmpty {
            bases.append(resolved)
        }
        bases.append(contentsOf: AevisHosts.accountCandidates)
        if bases.isEmpty { bases.append(AevisHosts.accountBase) }

        var seen = Set<String>()
        for raw in bases {
            var base = raw
            while base.hasSuffix("/") { base.removeLast() }
            guard !base.isEmpty, seen.insert(base).inserted else { continue }
            if await fetch(from: base) { return }
        }
        // 全都不通 → 安静用缓存，**绝不因此改行为**。
    }

    /// 从**一个**基址拉配置；拿到并写进缓存就返回 `true`。
    private func fetch(from base: String) async -> Bool {
        guard let url = URL(string: base + "/api/app/config") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = root["config"] as? [String: Any] else { return false }

            var fresh: [String: String] = [:]
            for (key, value) in config {
                fresh[key] = Self.text(from: value)
            }
            lock.lock()
            table = fresh
            lock.unlock()
            // 缓存一份（跟机器走，不跨设备）：下次冷启动第一帧就能读，不等网络。
            UserDefaults.standard.set(fresh, forKey: Self.cacheKey)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 取值

    /// 取一个字符串。没有这个键（或还没拉到）→ 返回 `fallback`。
    func string(_ key: String, `default` fallback: String = "") -> String {
        lock.lock()
        defer { lock.unlock() }
        return table[key] ?? fallback
    }

    /// 取一个开关。宽容解析 `1/true/yes/on` 与 `0/false/no/off`；认不出就返回 `fallback`。
    func bool(_ key: String, `default` fallback: Bool) -> Bool {
        lock.lock()
        let raw = table[key]
        lock.unlock()
        return Self.parseBool(raw) ?? fallback
    }

    /// 取一个整数。不是数字（或没有）→ 返回 `fallback`。
    func int(_ key: String, `default` fallback: Int) -> Int {
        lock.lock()
        let raw = table[key]
        lock.unlock()
        guard let raw = raw else { return fallback }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? fallback
    }

    // MARK: - 零件

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw = raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "y":
            return true
        case "0", "false", "no", "off", "n":
            return false
        default:
            return nil
        }
    }

    /// JSON 里的值可能是字符串，也可能是数字 / 布尔 —— 一律转成字符串。
    private static func text(from value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
