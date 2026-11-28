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
///
/// 2026-11-25 第二期（调度契约）：
/// - `/v1/app/config` 的 `data.features` 一起解析落缓存，客户端统一用 `featureEnabled(_:)` 读，
///   **键不存在 = false**（服务端不下命令即默认关闭）；
/// - **每次进程启动都拉一次**，不再有 6 小时 TTL 拦截（失败/空配置仍留旧缓存）；
/// - `/v1/ping` 同时读 `data.busy`，排序时把繁忙线路**排到后面但不删除**，
///   自动换线也复用这份实测结果。
enum AevisHosts {

    // MARK: - 存储键

    private static let cacheKey = "aevisCloudLines"        // JSON 数组：[{id,name,base}]
    private static let featureCacheKey = "aevisFeatureFlags" // JSON 字典：{featureName: Bool}
    /// 服务端**是否真的下发过** features 对象。
    /// `false` = 后端还没部署开关接口 → 走「兼容旧版全开」，绝不因为拿不到配置把模块全藏了。
    /// `true`  = 服务端已接管，未出现的键一律按 false（用户口径：不下命令就是关）。
    private static let featureSyncKey = "aevisFeatureSynced"
    private static var memoFeatureSynced: Bool?

    /// 内存缓存：避免每次读 `APIClient.lines` 都去解一次 JSON。
    /// `nil` = 还没初始化过；空数组 = 确实没有云端线路。
    private static var memo: [APIClient.Line]?
    /// 功能开关的内存镜像（`nil` = 还没从磁盘读过）。
    private static var memoFeatures: [String: Bool]?
    /// 最近一次 `/v1/ping`：线路 id → (RTT 毫秒, busy)。排序 / 状态页 / 自动换线共用。
    private static var pingState: [String: (rtt: Int, busy: Bool)] = [:]

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

    // MARK: - 功能开关（App 内模块门禁）

    /// 统一读取口：**键不存在 = false**（服务端未配置 / 读不到 = 不下命令 = 默认关闭）。
    /// SwiftUI 视图直接调它决定入口显示与否；已打开页面下次启动按新值生效。
    static func featureEnabled(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // 服务端从没下发过 features（后端未部署 / 新装用户还没拉到配置）：
        // 保持老版本行为，模块全部可见。否则发版当天用户会看到一个被掏空的 App。
        if !featureSyncedLocked() { return true }
        if let memoFeatures { return memoFeatures[name] ?? false }
        let cached = loadFeatures()
        memoFeatures = cached
        return cached[name] ?? false
    }

    /// 开关是否已由服务端接管（读内存 → 读磁盘）。调用方需已持锁。
    private static func featureSyncedLocked() -> Bool {
        if let memoFeatureSynced { return memoFeatureSynced }
        let synced = UserDefaults.standard.bool(forKey: featureSyncKey)
        memoFeatureSynced = synced
        return synced
    }

    /// 从 `/v1/app/config` 解析 `data.features`。
    /// 返回 nil = 服务端没下这个对象 / 下发了空对象 → 调用方保留旧缓存，不把用户打回全关。
    static func parseFeatures(_ json: [String: Any]) -> [String: Bool]? {
        let data = (json["data"] as? [String: Any]) ?? json
        let raw = (data["features"] as? [String: Any]) ?? (json["features"] as? [String: Any])
        guard let raw, !raw.isEmpty else { return nil }
        var out: [String: Bool] = [:]
        for (k, v) in raw {
            if let b = boolValue(v) { out[k] = b }
        }
        return out.isEmpty ? nil : out
    }

    /// 先读 UserDefaults；被清掉（重装 / 手动重置）时从 `.lineConfig` 硬缓存救回来。
    private static func loadFeatures() -> [String: Bool] {
        if let data = UserDefaults.standard.data(forKey: featureCacheKey),
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var out: [String: Bool] = [:]
            for (k, v) in raw { if let b = boolValue(v) { out[k] = b } }
            return out
        }
        guard let json = HardCache.cachedJSON(.lineConfig) else { return [:] }
        let data = (json["data"] as? [String: Any]) ?? json
        guard let raw = data["features"] as? [String: Any] else { return [:] }
        var out: [String: Bool] = [:]
        for (k, v) in raw { if let b = boolValue(v) { out[k] = b } }
        return out
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

    /// 拉云端配置 → 解析线路与开关 → 实测排序 → 落缓存。
    ///
    /// **每次 App 进程启动都拉一次**，不再用 6 小时 TTL 拦截（热更新靠服务端开关，
    /// 拦截会让用户永远吃旧值）。失败 / 空配置分支保留旧缓存，下次启动仍会再拉。
    ///
    /// 用 `APIClient.rawGet` 而不是 `request`：后者会读 `lines` → 读 `allAccountLines` →
    /// 回到这里，是环。`rawGet` 在**指定线路**上裸发一次请求，不参与回落。
    /// 调度入口**固定港区 aevis.lingyan.cyou**（2026-11-28：aevis.cn 腾出来备案、将停服）。
    /// 原来打北京 q7m3ax.lingyan.cyou —— 海外 DNS 根本解不出这个域名，等于冷启动永远拿不到配置。
    /// aevis.lingyan.cyou 解析到 38.76.168.61，国内海外都能解析，`/v1/` 已反代回主 API。
    /// 内置线路以后加新主力（新机）也绝不从新机拉配置 —— 调度源只有一个，避免两套真源。
    private static let configLine = APIClient.Line(
        id: "hk-config", name: "港区", base: "https://aevis.lingyan.cyou",
        pinning: false, note: ""
    )

    static func refresh() async {
        guard !configLine.base.isEmpty,
              let r = await APIClient.rawGet("/v1/app/config", line: configLine, timeout: 5),
              (200..<400).contains(r.status),
              let json = (try? JSONSerialization.jsonObject(with: r.data)) as? [String: Any]
        else { return }   // 调度机不可达：保留旧缓存，下次启动再拉

        let parsed = parse(json: json)
        if parsed.isEmpty {
            // 云端确实没配 / 全被过滤掉：**不要**用空结果覆盖旧缓存。
            // 服务端一次配置失误不该把用户的线路表 / 开关表清空。
            return
        }
        // features 空对象 = 保留旧开关；lines 有值才继续。
        let parsedFeatures = parseFeatures(json)
        let features = parsedFeatures ?? loadFeatures()
        // 内置 ∪ 云端一起探：排序要 RTT，自动换线要 busy，共用一份实测结果。
        await probeAndRecord(merge(builtIn: APIClient.builtInLines, cloud: parsed))
        let ranked = rankByLatency(parsed)
        store(ranked, features: features, synced: parsedFeatures != nil)
    }

    // MARK: - 实测排序 / ping 状态

    /// 并发探一组线路，结果记入 `pingState`（供排序、状态页、自动换线共用）。
    /// 并发上限就是线路条数，本 App 在这个量级；单条超时只有 2 秒。
    static func probeAndRecord(_ lines: [APIClient.Line]) async {
        await withTaskGroup(of: Void.self) { group in
            for line in lines where !line.base.isEmpty {
                group.addTask {
                    if let info = await APIClient.pingInfo(line) {
                        recordPing(line.id, rtt: info.rtt, busy: info.busy)
                    }
                }
            }
            for await _ in group { }
        }
    }

    /// 记入单次实测结果（状态页探测后也调它，保证自动换线吃到的 busy 不是过期的）。
    static func recordPing(_ id: String, rtt: Int, busy: Bool) {
        lock.lock()
        pingState[id] = (rtt, busy)
        lock.unlock()
    }

    /// 最近一次 ping 的 busy 标记。没测过 = false（探针读不到负载时也是 false）。
    static func isBusy(_ lineID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pingState[lineID]?.busy ?? false
    }

    /// 最近一次 ping 的 RTT（毫秒）。没测过 = nil。
    static func latency(_ lineID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return pingState[lineID]?.rtt
    }

    /// 最佳候选：可达、非 busy、RTT 最小；排除当前线路。自动换线专用。
    static func bestCandidate(excluding id: String) -> (line: APIClient.Line, rtt: Int)? {
        // 先取线路表：`allAccountLines` 内部也会拿 lock，持锁调用会死锁。
        let pool = APIClient.lines.filter { !$0.base.isEmpty && $0.id != id }
        lock.lock()
        defer { lock.unlock() }
        var best: (line: APIClient.Line, rtt: Int)?
        for line in pool {
            guard let s = pingState[line.id], !s.busy else { continue }
            if let cur = best {
                if s.rtt < cur.rtt { best = (line, s.rtt) }
            } else {
                best = (line, s.rtt)
            }
        }
        return best
    }

    /// 按 `/v1/ping` 实测结果排序：**非 busy 的按 RTT 升序在前，busy 的排到后面（不删除）**；
    /// 不可达的仍从候选里剔除（连不通的地址只会让回落白等一个超时，比误报更糟）。
    /// 同 RTT / 同 busy 按原序，稳定不跳。
    static func rankByLatency(_ lines: [APIClient.Line]) -> [APIClient.Line] {
        guard !lines.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return lines.enumerated()
            .filter { pingState[$0.element.id] != nil }
            .sorted { a, b in
                let sa = pingState[a.element.id]!
                let sb = pingState[b.element.id]!
                if sa.busy != sb.busy { return !sa.busy }
                if sa.rtt != sb.rtt { return sa.rtt < sb.rtt }
                return a.offset < b.offset
            }
            .map { $0.element }
    }

    // MARK: - 缓存

    private static func store(_ lines: [APIClient.Line], features: [String: Bool], synced: Bool = false) {
        let rows: [[String: String]] = lines.map {
            ["id": $0.id, "name": $0.name, "base": $0.base]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        var featureAny: [String: Any] = [:]
        for (k, v) in features { featureAny[k] = v }
        if let data = try? JSONSerialization.data(withJSONObject: featureAny) {
            UserDefaults.standard.set(data, forKey: featureCacheKey)
        }
        // 2.8：线路配置也进统一硬缓存。UserDefaults 是轻量备份，
        // 换机 / 重装后 Documents 还在时能从这里恢复，不必等网络。
        // features 和 lines 放同一个 .lineConfig，避免为开关新增 HardCache 枚举值。
        HardCache.saveJSON(.lineConfig, ["lines": rows, "features": featureAny])
        // 只有服务端真的下发了 features，才把开关交给它管；否则维持「全开」兼容态。
        if synced { UserDefaults.standard.set(true, forKey: featureSyncKey) }
        lock.lock()
        memo = lines
        memoFeatures = features
        if synced { memoFeatureSynced = true }
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
        UserDefaults.standard.removeObject(forKey: featureCacheKey)
        UserDefaults.standard.removeObject(forKey: featureSyncKey)   // 回到「全开」兼容态，下次启动重新拉
        HardCache.remove(.lineConfig)   // 2.8：两个缓存一起清，否则重置后又被硬缓存救回来
        lock.lock()
        memo = []
        memoFeatures = [:]
        memoFeatureSynced = nil
        pingState = [:]
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
