import Foundation

/// 动态下发线路（2026-11-25，集群方案 T02）。
///
/// 背景：原来的线路表是**编进 App 的常量**（`APIClient.builtInLines`），加一台机器就得
/// 发一次新版；线上 `app_account_lines` 早就能配了，只是端上从来没读。这里把云端那张表接上。
///
/// 三条硬约束（架构方案 §12 第 22 条，写死的，别改）：
/// 1. **云端只定「有哪些」，顺序不参与优先级** —— 服务端返回的数组顺序一律忽略。
///    `order` / `priority` 这类字段即使出现也不读，绝不能变成第二个排序真源。
/// 2. **`enabled == false` / `weight <= 0` 直接剔除**。字段缺省视为启用
///    （线上现在只下发 `base` + `name`，没有这两个字段）。
/// 3. **最终顺序由本地实测决定**，不是云端说的。实测用 `/v1/ping`
///    （零 DB、零鉴权的探针），**429/503 算可达并计入 RTT** —— 被限流不等于线路挂了；
///    只有超时和连接失败才判不可达。
///
/// 为什么不可达的云端线路要**从列表里去掉**而不是排到最后：
/// 连不通的地址会让每次回落白等一个 `timeoutInterval`，症状是「偶发慢」而不是报错，
/// 是最难查的那类故障。宁可它压根不在候选里。
///
/// 缓存：合并结果存 `UserDefaults`，冷启动不联网也能用上一轮的结论；
/// 云端返回空/解析失败时**保留旧缓存**，绝不把用户打回"只有内置两条"然后再也回不来。
enum AevisHosts {

    // MARK: - 存储键

    private static let cacheKey = "aevisCloudLines"       // JSON 数组：[{id,name,base}]
    private static let probedKey = "aevisCloudLinesAt"    // 上次实测时间（秒）

    /// 实测结果的最长保鲜期（秒）。超过就重新测 —— 线路质量会变，不能吃一辈子旧数据。
    private static let probeTTL: TimeInterval = 6 * 60 * 60

    /// 内存缓存：避免每次读 `APIClient.lines` 都去解一次 JSON。
    /// `nil` = 还没初始化过；空数组 = 确实没有云端线路。
    private static var memo: [APIClient.Line]?

    private static let lock = NSLock()

    // MARK: - 对外：合并后的线路表

    /// 内置 ∪ 云端，按 base 去重，**内置优先**（内置条目带着 `pinning` 等本地语义，
    /// 不能被云端同名地址覆盖掉）。
    ///
    /// 这是 `APIClient.lines` 的实际来源 —— 所以所有已有的线路 UI / 回落逻辑
    /// （登录页选线、状态页列表、失败降权）自动就能看到云端线路，不用改一行。
    static var allAccountLines: [APIClient.Line] {
        lock.lock()
        defer { lock.unlock() }
        if let memo { return merge(builtIn: APIClient.builtInLines, cloud: memo) }
        let cached = loadCache()
        memo = cached
        return merge(builtIn: APIClient.builtInLines, cloud: cached)
    }

    /// 云端下发的原始线路（已过滤 `enabled=false` / `weight<=0`、已按实测 RTT 排序）。
    /// 不含内置线路 —— 想拿完整表用 `allAccountLines`。
    static var cloudLines: [APIClient.Line] {
        lock.lock()
        defer { lock.unlock() }
        if let memo { return memo }
        let cached = loadCache()
        memo = cached
        return cached
    }

    // MARK: - 解析

    /// 从 `/v1/app/config` 的响应里取 `data.lines` 并转成 `Line`。
    ///
    /// 容错到「宁可少一条，不能崩一次」：
    /// - 外层信封可能已被摊平（`request` 会摊），所以 `data` / 顶层两处都找；
    /// - `base` 兼容 `base` / `url` / `host` 三种写法，缺一个就跳过这条；
    /// - 只收 `http(s)://` 开头的地址，别的协议（`itms-services` 之类）不可能是 API 线路；
    /// - 地址末尾的 `/` 统一去掉，否则 `/v1/ping` 会拼成 `//v1/ping`。
    static func parse(json: [String: Any]) -> [APIClient.Line] {
        let data = (json["data"] as? [String: Any]) ?? json
        let raw = (data["lines"] as? [[String: Any]])
            ?? (json["lines"] as? [[String: Any]])
            ?? []
        var out: [APIClient.Line] = []
        for (idx, row) in raw.enumerated() {
            guard let base = normalizeBase(
                (row["base"] as? String) ?? (row["url"] as? String) ?? (row["host"] as? String)
            ) else { continue }

            // 硬约束 2：显式关闭 / 权重归零的直接剔除。字段缺省 = 启用（线上现在就没有这两个字段）。
            if let enabled = boolValue(row["enabled"]), !enabled { continue }
            if let weight = doubleValue(row["weight"]), weight <= 0 { continue }

            let name = ((row["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // id 必须是**由 base 派生的稳定值**：
            // - 不能用云端给的 id（服务端改一次 id，用户的 `apiLineId` 就指向不存在的线路）；
            // - 不能用数组下标（服务端调顺序 → id 全变 → 用户选过的线路失效）；
            // - 不能用 `abs(hashValue)`（`Int.min` 取绝对值会 trap，是真实的崩溃点）。
            // 这里用 31 进制的确定性散列，同一 base 永远得到同一个 id。
            out.append(APIClient.Line(
                id: "cloud-" + stableKey(base),
                name: name.isEmpty ? "线路 \(idx + 1)" : name,
                base: base,
                // 硬约束：动态下发的线路**绝不当自签证书处理**。
                // 内置的「直连」是唯一 pinning 的线路，它靠 base 去重被保留在内置那一侧。
                pinning: false,
                note: ""
            ))
        }
        return out
    }

    // MARK: - 刷新（启动时调一次）

    /// 拉云端线路 → 解析 → 按 `/v1/ping` 实测 RTT 排序 → 落缓存。
    ///
    /// 用 `APIClient.rawGet` 而不是 `request`：后者会读 `lines` → 读 `allAccountLines` →
    /// 回到这里，是环。`rawGet` 在**指定线路**上裸发一次请求，不参与回落。
    static func refresh() async {
        if !shouldProbe() { return }        // TTL 内且已有缓存：不必再联网

        for line in APIClient.builtInLines where !line.base.isEmpty {
            guard let r = await APIClient.rawGet("/v1/app/config", line: line, timeout: 5),
                  (200..<400).contains(r.status),
                  let json = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
            else { continue }

            let parsed = parse(json: json)
            if parsed.isEmpty {
                // 云端确实没配 / 全被过滤掉：**不要**用空结果覆盖旧缓存。
                // 服务端一次配置失误不该把用户的线路表清空。
                return
            }
            let ranked = await rankByLatency(parsed)
            store(ranked)
            return
        }
        // 一条内置线路都没拉到：保留旧缓存，不做任何写入
    }

    // MARK: - 实测排序

    /// 按 `/v1/ping` 实测 RTT 升序；不可达的直接剔除。
    ///
    /// 并发测：串行测 4 条就是 4 个超时叠起来，启动会被拖住。
    /// 并发上限 4 条，本 App 的线路数量在这个量级。
    static func rankByLatency(_ lines: [APIClient.Line]) async -> [APIClient.Line] {
        guard !lines.isEmpty else { return [] }

        // 结果用"索引 → 延迟"收集，避免并发写同一个数组
        let results: [Int: Int] = await withTaskGroup(of: (Int, Int?).self) { group in
            for (idx, line) in lines.enumerated() {
                group.addTask { (idx, await APIClient.pingLatency(line)) }
            }
            var acc: [Int: Int] = [:]
            for await (idx, rtt) in group {
                if let rtt { acc[idx] = rtt }
            }
            return acc
        }

        // 可达的按 RTT 升序；同 RTT 按原序（稳定，不会每次刷新都跳）
        let reachable = lines.enumerated()
            .filter { results[$0.offset] != nil }
            .sorted { a, b in
                let la = results[a.offset] ?? Int.max
                let lb = results[b.offset] ?? Int.max
                return la == lb ? a.offset < b.offset : la < lb
            }
            .map { $0.element }

        return reachable
    }

    // MARK: - 缓存

    private static func shouldProbe() -> Bool {
        let at = UserDefaults.standard.double(forKey: probedKey)
        guard at > 0 else { return true }
        let age = Date().timeIntervalSince1970 - at
        // 缓存为空时必须重测（可能是首次启动 / 上次全不可达）
        if cloudLines.isEmpty { return true }
        return age > probeTTL || age < 0     // age < 0：用户把系统时间往回调过
    }

    private static func store(_ lines: [APIClient.Line]) {
        let rows: [[String: String]] = lines.map {
            ["id": $0.id, "name": $0.name, "base": $0.base]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        // 2.8：线路配置也进统一硬缓存。UserDefaults 是轻量备份，
        // 换机 / 重装后 Documents 还在时能从这里恢复，不必等网络。
        HardCache.saveJSON(.lineConfig, ["lines": rows])
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: probedKey)
        lock.lock()
        memo = lines
        lock.unlock()
    }

    private static func loadCache() -> [APIClient.Line] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]]
        else {
            // 2.8：UserDefaults 被清掉（重装 / 手动重置）时，从统一硬缓存救回来。
            guard let json = HardCache.cachedJSON(.lineConfig) else { return [] }
            return parse(json: json)
        }
        var out: [APIClient.Line] = []
        for row in rows {
            guard let base = normalizeBase(row["base"]), let id = row["id"], !id.isEmpty else { continue }
            out.append(APIClient.Line(
                id: id,
                name: row["name"].flatMap { $0.isEmpty ? nil : $0 } ?? "线路",
                base: base,
                pinning: false,
                note: ""
            ))
        }
        return out
    }

    /// 清空云端缓存（状态页「重置线路」用；也让下次启动必然重新拉一遍）。
    static func clear() {
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: probedKey)
        HardCache.remove(.lineConfig)   // 2.8：两个缓存一起清，否则重置后又被硬缓存救回来
        lock.lock()
        memo = []
        lock.unlock()
    }

    // MARK: - 合并 / 规整

    /// 内置在前、云端在后，按 `base` 去重（内置优先，保住 `pinning` 等本地语义）。
    static func merge(builtIn: [APIClient.Line], cloud: [APIClient.Line]) -> [APIClient.Line] {
        var seen = Set<String>()
        var out: [APIClient.Line] = []
        for l in builtIn {
            let key = normalizeBase(l.base) ?? l.id
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(l)
        }
        for l in cloud {
            guard let key = normalizeBase(l.base) else { continue }
            if seen.contains(key) { continue }     // 云端重复下发了内置的那两条 → 忽略
            seen.insert(key)
            out.append(l)
        }
        return out
    }

    /// 由 base 派生一个**确定性**的短 key（同一地址永远得到同一个值）。
    ///
    /// 为什么不用 `hashValue`：Swift 的 `hashValue` 每次进程启动都会变（加了随机种子），
    /// 拿它当持久化 id 会让用户选过的线路每次冷启动都"失效"。
    /// 这里用 31 进制滚动散列，纯函数、跨进程稳定。
    static func stableKey(_ s: String) -> String {
        var h: UInt32 = 5381
        for b in s.utf8 {
            h = (h &* 31) &+ UInt32(b)
        }
        return String(h, radix: 36)
    }

    /// 地址规整：去空白、去末尾 `/`、必须 http(s)。不合法返回 nil。
    static func normalizeBase(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        while s.hasSuffix("/") { s.removeLast() }
        let lower = s.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        // 只剩协议头（"https://"）也算无效
        guard s.count > 8 else { return nil }
        return s
    }

    /// 宽松布尔：真 bool / 1-0 / "true"-"false" 都认。
    private static func boolValue(_ any: Any?) -> Bool? {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "true" || t == "1" || t == "yes" { return true }
            if t == "false" || t == "0" || t == "no" { return false }
        }
        return nil
    }

    /// 宽松数值：NSNumber / 数字字符串都认。
    private static func doubleValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
