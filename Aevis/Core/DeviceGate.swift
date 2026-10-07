// ⚠️ 用 SwiftUI 而不是 Foundation：`ObservableObject` / `@Published` 是 Combine 的东西，
// 而本机没有 Xcode，少一个 import 就要白烧一轮 CI 才发现。
import SwiftUI
// ⭐ 2026-10-07 一天体验码：`TrialClock` 用 `ProcessInfo.systemUptime`（单调钟）+ DateFormatter，
// 两个都在 Foundation 里。补一个显式 import，别指望 SwiftUI 转出来。
import Foundation

/// 「一天体验码」的到期判据 —— **服务端权威 + 本地单调倒计时**。
///
/// ## 为什么不能只拿 `Date()` 跟一个到期时刻比
/// 那样用户把手机时间往回调，24 小时就变成无限长。所以每次联网核到时，
/// 把服务端给的 `expires_at - now` 换成一个**倒计时秒数**，连同当时的
/// `systemUptime`（单调钟，改系统时间动不了）一起存进钥匙串。之后本地判断
/// 一律走 `systemUptime` 的增量 —— **改系统时间不影响它**。
///
/// 唯一会退化的情形：**重启过**（`systemUptime` 归零，单调锚点失效）**且**当时离线。
/// 这时退回用墙上时钟（`Date`）比 —— 理论上能被"重启 + 改时间 + 断网"绕过，
/// 但代价极高、普通用户不会这么干；而老板真正要防的"随手把时间改一下"已经被挡住。
///
/// ## 存哪
/// **钥匙串**（`Keychain`）—— 卸载重装默认还在，比 `UserDefaults` 难清。
/// 存的是一小段 JSON：还剩多少秒 / 当时的 uptime / 当时的墙上时间 / 到期时刻。
enum TrialClock {
    private static let key = "aevis.trial.window"

    /// 宽限（秒）。倒计时走完之后再多给这一小段才锁 ——
    /// 只为吸收联网往返 / 取整误差，**不是**给用户续命（对 24 小时来说可忽略）。
    static let graceSeconds: TimeInterval = 5 * 60

    /// 存一个"还剩多少秒"的窗口（从服务端核到的那一刻算起）。
    ///
    /// `serverOver`：**服务端显式判定"已过期"** —— 一旦置上，本地宽限也压不住，
    /// 直接判过期（见 `isExpired()`）。续费 / 转永久时会被 `clear()` 或下次写入覆盖掉。
    static func save(remaining: TimeInterval, expiresAt: Int, serverOver: Bool = false) {
        let payload: [String: Any] = [
            "remaining": remaining,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "wall": Date().timeIntervalSince1970,
            "expiresAt": expiresAt,
            "serverOver": serverOver,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            Keychain.set(text, for: key)
        }
    }

    /// 清掉体验窗口（永久账号 / 账号被删时调用）。
    static func clear() { Keychain.remove(key) }

    /// 钥匙串里记的到期时刻（Unix 秒）。没有 / 非体验 = nil。
    static func storedExpiresAt() -> Int? {
        guard let obj = load() else { return nil }
        let exp = obj["expiresAt"] as? Int ?? 0
        return exp > 0 ? exp : nil
    }

    /// 钥匙串里记的"服务端判过已过期"标记。没有 = false。
    static func storedServerOver() -> Bool {
        guard let obj = load() else { return false }
        return (obj["serverOver"] as? Bool) ?? false
    }

    /// 本地还算不算"还没到期"。**没有记录 = 永久 / 未知 → 不算过期**（宁可放过）。
    ///
    /// ⚠️ 只要服务端显式说过"已过期"（`serverOver`），这里**一律**判过期 ——
    ///    本地宽限（`graceSeconds`）只用来吸收联网误差，**不能**推翻服务端的判定。
    static func isExpired() -> Bool {
        guard let obj = load() else { return false }
        if (obj["serverOver"] as? Bool) ?? false { return true }
        guard let left = remaining() else { return false }
        return left + graceSeconds <= 0
    }

    /// 本地还剩多少秒（负数 = 已经过了多久）。没有记录 = nil。
    static func remaining() -> TimeInterval? {
        guard let obj = load(),
              let base = obj["remaining"] as? Double,
              let anchorUptime = obj["uptime"] as? Double
        else { return nil }
        let anchorWall = obj["wall"] as? Double ?? 0
        let nowUptime = ProcessInfo.processInfo.systemUptime
        if nowUptime >= anchorUptime {
            // ⭐ 单调路径：**改系统时间动不了它** —— 这是防改时间的核心。
            return base - (nowUptime - anchorUptime)
        }
        // 重启过（systemUptime 归零）→ 退回墙上时钟（见类型注释）。
        return base - max(0, Date().timeIntervalSince1970 - anchorWall)
    }

    private static func load() -> [String: Any]? {
        guard let text = Keychain.get(key), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// 授权门禁 —— 「这台设备到底能不能进 App」。
///
/// ## 用户定的口径（2026-09-25）
/// 「打开 APP 就提示没有授权，然后就展示设备码和没有授权的那个界面」
/// 「填设备码之后就自动通过，就是一个账号一个设备码」。
///
/// 所以整条链路是：
/// ```
/// 打开 App → 这台设备没授权 → 只显示设备码那一屏
///          → 用户去网页登录账号、把设备码填进去
///          → 绑定成功 = 授权通过 → App 自己发现，自动进去
/// ```
///
/// ## 三个必须守住的点
/// 1. **授权一次就永久记住**（存本机）。要是每次启动都要联网确认，
///    服务器抖一下、用户在地铁里没信号，他就打不开自己的聊天记录了 ——
///    这个 App 的价值全在本地数据里，那种锁法等于自毁。
/// 2. **老用户不能被升级关在门外**。他已经装着、用着、有聊天记录了，
///    新版本一装发现"没授权"就拦住，他第一反应是"你把我的东西弄没了"。
///    认的办法很简单：**本地已经有联系人 = 他本来就在用**（新装的人不可能有）。
/// 3. **查不到 ≠ 没授权**。网络失败只是"这次没查到"，
///    绝不能拿它去撤销一个已经生效的授权。
///
/// ## ⚠️ 2026-10-07 修正：断一下不撤销，但**连续够不着够久就锁**
/// 老板补了要求：「如果检测到没有连到服务器的话，就直接锁」（防破解版把服务器地址
/// patch 掉）。这跟上面第 3 条**看似冲突**，处置上是这么合并成一套口径的 ——
///   · `authorized`（授权标记）**照旧不撤销**：断网不把人踢成"未授权"，本地数据一条不动。
///   · 另立一个维度 `unreachable`：**连续**够不着服务器 ≥ `offlineLockAfter`（5 分钟）
///     才置真，`isBlocking` 随之拦住；**只要够得着服务器一次就清零**。
///   ⇒ 统一成：**"偶发 / 短时离线（时间窗内）= 宽限，不锁；持续连不上（超过时间窗）= 锁"**。
///     分界线是"有没有连续超过时间窗"，而不是"有没有一次失败" —— 见 `noteServerMiss()`。
///
/// ## ⚠️ 为什么整个类必须是 `@MainActor`（2026-09-26 从后台真机报告里抓出来的真凶）
/// 这个类里**两个 async 方法都会改 `@Published`**：`refresh()`（改 8 个）
/// 和 `revokeBecauseAccountGone()`（改 `authorized` / `account` / 两个 `deviceAuthorized`）。
/// 而 Swift 5.5 起，**非隔离的 async 函数在 `await` 之后会跳回全局并发池执行** ——
/// 调用点写 `Task { await gate.refresh() }` 也管不住函数体。
/// 于是那些 `@Published` 是在后台线程改的，**iOS 26 上直接硬崩**。
///
/// 真机现场对得上（后台诊断 `AE-155A-91FC`，iPhone15,3 / 0.0.62）：
/// BlackBox 里最后一行正好是 `revokeBecauseAccountGone()` 里那句
/// 「⚠️ 账号已不存在 → 退回未授权」，写完进程就没了。
///
/// 和 `MusicPlayer` 是同一个坑（那边已经这么修了），照着来。
@MainActor
final class DeviceGate: ObservableObject {

    static let shared = DeviceGate()

    /// 阈值（秒）的**下限 / 上限** —— 服务端下发的 `offline_grace` 会被钳到这个区间。
    ///
    /// ⚠️ 下限 60 是防呆：这个值一旦被下发成 0 / 负数，所有人一断网立刻锁，
    ///    等于自己把服务搞挂。上限 3600 防"配得太大形同没锁"。
    private static let offlineGraceMin: TimeInterval = 60
    private static let offlineGraceMax: TimeInterval = 3600

    /// 当前生效的"连续够不着服务器多久算异常 → 锁"阈值（秒）。
    ///
    /// 默认 **300（5 分钟）**：地铁 / 隧道 / 电梯里断续几分钟不该误伤；而把服务器地址
    /// patch 掉的破解版是**永远**够不着，超过阈值后彻底用不了。
    /// 每次联网拿服务端 `/api/device/lookup` 的 `offline_grace` 覆盖（并钳位，
    /// 见 `applyOfflineGrace`）—— 不用重新发包就能调松 / 调紧。
    /// 判定用"时间窗"（从第一次 miss 起算），轮询频率（30 秒 / 回前台 / 门禁页 5 秒）
    /// 怎么变都不影响结果 —— 复用现成的 30 秒轮询，不新造定时器。
    private var offlineLockAfter: TimeInterval = 300

    /// 这台设备已经通过授权。
    @Published private(set) var authorized: Bool = false
    /// 正在查。
    @Published private(set) var checking: Bool = false
    /// 授权时绑的那个账号（服务器给的就是打码过的邮箱）。
    @Published private(set) var account: String?
    /// 上一次查询出的问题（连不上之类）。**只用来提示，不拦人。**
    @Published private(set) var problem: String?
    /// 至少查成功过一次 —— 界面据此把"没连上"和"确实还没绑"分开说。
    @Published private(set) var reachedServer: Bool = false

    /// 这台设备**被后台停用了**。
    ///
    /// 跟「没授权」是两回事：「没授权」是"还没绑过"，「被封」是"被停用"——
    /// 界面上要说的话完全不同，所以单独一个状态。
    ///
    /// ⚠️ 每次查询都会重新问，所以**后台点"解封"是自动生效的**，
    /// 不用用户做任何事。
    @Published private(set) var blocked: Bool = false

    /// ⭐ 一天体验：这台设备的到期时刻（Unix 秒）。nil = 永久账号（旧口径）。
    ///
    /// 来源是**服务端权威**（`/api/device/lookup` 回的 `expires_at`），本地只是缓存。
    @Published private(set) var trialExpiresAt: Int?

    /// ⭐ 本地判出来"体验已经到期了"。**App 就靠它自动锁上**（见 `isBlocking`）。
    @Published private(set) var trialOver: Bool = false

    /// ⭐ 2026-10-07（老板：「如果检测到没有连到服务器的话，就直接锁」）：**连续够不着服务器**。
    ///
    /// 破解版常见的做法是把 App 里的服务器地址 patch 掉 —— 那样它**永远**连不上真服务器。
    /// 所以"连续够不着 ≥ `offlineLockAfter`"本身就是一个要拦的信号。
    ///
    /// ⚠️ 跟"偶尔断一下"必须分开：只有**连续**够不着累计到阈值才置真；
    ///    任何一次成功拿到 HTTP 回应都会把它清零（`noteServerHit()`）。
    @Published private(set) var unreachable: Bool = false

    /// 连续够不着服务器的起点（墙上时间 Unix 秒）**存在 UserDefaults 里**（`outageKey`）。
    ///
    /// ⚠️ 落盘是**故意**的：不然被强杀 / 重启一次，时间窗就从 0 重算 —— 破解版
    ///    每 <5 分钟强杀一次就能续命。落盘后"飞机上杀掉再开，窗口继续走"。
    ///    **只存时间戳**，不存 `consecutiveMisses`（我们按时间窗判定，次数没意义）。
    private static let outageKey = "aevis.gate.outage"
    /// 连续够不着服务器的次数 —— 只用于日志 / 排查，判定用的是"时间窗"。
    private var consecutiveMisses = 0

    /// 上次把体验窗口落进钥匙串的墙上时间 —— 用来节流，别每 30 秒写一次钥匙串。
    private var lastTrialSave: TimeInterval = 0

    /// 防止两个调用点同时发起查询（视图的定时循环 + 回到前台各一次）。
    private var inFlight = false
    /// 同上，给「账号还在不在」那次查询用。
    private var verifying = false

    private init() {
        // ⚠️ 截图专用开关：`-aevisShowGate` 时**必须当成"从没授权过的新设备"**。
        // 否则 demo 数据里的联系人会命中下面那条"老用户免过"，
        // 于是门禁页上会出现「已经授权了。」这种自相矛盾的话（build-55 的截图里就是这样）。
        // 正式版没有这个参数，走不到这里。
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-aevisShowGate") { return }
        #endif

        let settings = AppSettings.shared
        if settings.deviceAuthorized {
            authorized = true
            let saved = settings.deviceAuthorizedAccount
            account = saved.isEmpty ? nil : saved
        } else if !PersonaStore.shared.isEmpty {
            // 老用户：本地已经有联系人，说明这台机器上本来就装着、用着。
            // **顺手把标记补上**，以后就按正常流程走。
            authorized = true
            settings.deviceAuthorized = true
        }
        // ⭐ 冷启动就地判一次体验到期（钥匙串里可能存着上一轮联网核到的窗口）。
        evaluateTrial()
    }

    // MARK: - 要不要拦

    /// 入口该不该被挡住。
    var isBlocking: Bool {
        // ⚠️ 截图自检用：这几个开关只能在 Debug 里读，
        // 正式版编不进 `ProcessInfo` 那一段。
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        // 显式要看门禁页（截图用）—— 放在最前面，否则本机存过授权就截不到
        if args.contains("-aevisShowGate") { return true }
        // 模拟器截图不该被门禁挡着，否则三十多张图全是同一屏
        if args.contains("-aevisSkipGate") || args.contains("-aevisDemo") { return false }
        #endif
        // 被封 → 一样拦住。放在 `!authorized` 前面 ——
        // 被封的设备，`authorized` 也已经被清成 false 了，两条路结论一样，
        // 但先说"被封"能让界面知道该显示哪一屏。
        if blocked { return true }
        // ⭐ 一天体验到期 → 一样拦住。**这是"App 自己锁上"的落点**，
        //    不靠后台点任何东西 —— 时间一到，本地倒计时走完就锁。
        if trialOver { return true }
        // ⭐ 连续够不着服务器（≥ `offlineLockAfter`）→ 一样拦住（防破解版屏蔽服务器地址）。
        //    放在 `!authorized` 之前 —— 界面据此显示"连不上服务器"那一屏。
        if unreachable { return true }
        return !authorized
    }

    // MARK: - 查

    /// 查一次服务器：这张设备码绑出去没有。
    ///
    /// 走的是 `/api/device/lookup` —— 那个接口**故意不需要登录**：
    /// 绑定发生在网页上，App 这边没有登录态；而它只回
    /// 「绑没绑 + 一串打码邮箱 + 绑定时间」，没有任何可利用的信息。
    func refresh() async {
        if inFlight { return }
        inFlight = true
        checking = true
        defer {
            inFlight = false
            checking = false
        }

        // ⭐ 每次刷新（含断网这次）都先就地重算"体验到期了没有"。
        //    放在网络之前 —— 就算请求失败，24 小时一到这里照样会把 App 锁上。
        evaluateTrial()

        guard let url = lookupURL() else {
            // ⚠️ 拼不出地址也是一种"够不着服务器"（多半被改过配置）—— 记一次 miss。
            problem = "设备码拼不出查询地址，重装一次 App 试试。"
            noteServerMiss()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 这个结果必须是最新的 —— 用户刚在网页上点完"绑定"就切回来，
        // 缓存会把旧的 `bound:false` 又喂给他一遍。
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                problem = "服务器没回正经东西，等会儿再试。"
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            // ✅ 拿到了 HTTP 回应 = 够得着服务器 → 清掉"异常离线"的计数 / 时间窗。
            noteServerHit()
            // ⭐ 服务端下发的"断网多久算异常"宽限值（钳位后生效，见 applyOfflineGrace）。
            applyOfflineGrace(json["offline_grace"] as? Int)

            guard http.statusCode == 200 else {
                problem = "服务器说：\((json["message"] as? String) ?? "HTTP \(http.statusCode)")"
                return
            }

            // ⚠️ **先看被封**。服务器说这台被停用了，就别再管 bound 是什么。
            if (json["blocked"] as? Bool) ?? false {
                blocked = true
                authorized = false
                // ⚠️ 本地那个"已授权"标记也要清掉。
                // 不清的话，下次启动 `init()` 又按它免检放行 ——
                // 断网时能钻出去用（被封的设备不该有这条路）。
                // 代价是被封的人必须联网才能恢复，但**解封后第一次查询会自动放行**。
                AppSettings.shared.deviceAuthorized = false
                problem = nil
                return
            }
            // 没封（或者刚被解封）→ 清掉标记，让下面的正常流程接管
            blocked = false

            if (json["bound"] as? Bool) ?? false {
                // ⭐ 服务端权威的体验到期时间（永久账号是 nil）+ 服务端当前时间（防改时间锚点）。
                let exp = json["expires_at"] as? Int
                let srvNow = json["now"] as? Int
                // ⭐ 服务端**显式**判定的"这台设备现在锁了没有"（服务器拿 devices.expires_at
                //    比服务器当前时间算出来的）。为真就必须**立刻**锁 ——
                //    不允许只靠本地倒计时推（老板 2026-10-07：「服务器那边检测到的话，也锁」）。
                let srvOver = (json["trial_over"] as? Bool) ?? false
                // 已经授权过就别再 grant 一遍了：那个方法会往 UserDefaults 写东西，
                // 而现在是**隔一会儿就查一次**，没必要每次都写。
                if !authorized {
                    grant(account: json["account"] as? String,
                          expiresAt: exp, serverNow: srvNow, serverSaysOver: srvOver)
                } else {
                    // 已授权：把服务端给的到期时间同步成本地窗口（续费后会变成 nil → 解锁）。
                    syncTrial(expiresAt: exp, serverNow: srvNow, serverSaysOver: srvOver)
                }
            } else {
                // 还没绑 —— 这是最正常的状态，不是错误
                problem = nil
            }
        } catch {
            // 断网/超时。**不撤销已有授权**（原来的口径：断一下不能把人踢出去），
            // 但记一次 miss —— 连着够不着够久就会走 `unreachable` 这条锁（见 `noteServerMiss`）。
            problem = "没连上服务器（\(error.localizedDescription)）"
            noteServerMiss()
        }
    }

    // MARK: - 授权通过

    /// 记下"这台设备通过了"。**写入本机，之后就再也不查了。**
    func grant(account masked: String?, expiresAt: Int? = nil, serverNow: Int? = nil,
               serverSaysOver: Bool = false) {
        let settings = AppSettings.shared
        authorized = true
        account = masked
        problem = nil
        reachedServer = true
        settings.deviceAuthorized = true
        settings.deviceAuthorizedAccount = masked ?? ""
        syncTrial(expiresAt: expiresAt, serverNow: serverNow, serverSaysOver: serverSaysOver)
    }

    // MARK: - 一天体验到期

    /// 把服务端给的到期时间同步成本地倒计时窗口（并存进钥匙串）。
    ///
    /// ⚠️ **到期时间只有服务端说了算** —— 本地这条 `trialOver` 全是从这里推出来的；
    ///    客户端从不自己"加时间"，断网时只会拿着单调钟继续往下数（见 `TrialClock`）。
    ///
    /// `serverSaysOver`：服务端 `/api/device/lookup` 显式回的"这台设备已经锁了"。
    ///   为真时**立刻**锁（往钥匙串落一个 `serverOver` 标记，本地宽限压不住它），
    ///   不看本地倒计时还剩多少 —— 老板要的就是「服务器检测到就锁」。
    private func syncTrial(expiresAt: Int?, serverNow: Int?, serverSaysOver: Bool = false) {
        guard let exp = expiresAt, exp > 0 else {
            // 永久账号 / 正式购买 / 续费到账 → 清掉体验窗口，别再锁人。
            trialExpiresAt = nil
            trialOver = false
            lastTrialSave = 0
            TrialClock.clear()
            return
        }
        let changed = trialExpiresAt != exp
        trialExpiresAt = exp
        let now = serverNow ?? Int(Date().timeIntervalSince1970)
        let wall = Date().timeIntervalSince1970
        // ⭐ 服务端说"已锁" → 落盘 serverOver 标记并**立刻**上锁，优先级最高。
        if serverSaysOver {
            TrialClock.save(remaining: TimeInterval(exp - now), expiresAt: exp, serverOver: true)
            lastTrialSave = wall
            trialOver = true
            return
        }
        // 别每 30 秒都写一次钥匙串：到期时间没变、且距上次落盘不到 5 分钟就跳过。
        // ⚠️ 但上一轮服务端判过"锁"的话，这次必须落盘把它清掉（续费 / 管理员解开）。
        var needSave = changed || lastTrialSave == 0 || wall - lastTrialSave > 300
        if TrialClock.storedServerOver() { needSave = true }
        if needSave {
            TrialClock.save(remaining: TimeInterval(exp - now), expiresAt: exp)
            lastTrialSave = wall
        }
        evaluateTrial()
    }

    /// 按本地窗口重算"到期了没有"。**纯本地、不联网。**
    private func evaluateTrial() {
        if trialExpiresAt == nil { trialExpiresAt = TrialClock.storedExpiresAt() }
        let over = TrialClock.isExpired()
        if over != trialOver { trialOver = over }
    }

    // MARK: - 够不够得着服务器（2026-10-07：「检测到没连到服务器就直接锁」）

    /// ✅ 拿到了服务器回应（任何状态码都算）→ 清掉"异常离线"。
    ///
    /// ⚠️ 这一条就是"正常离线"与"异常离线"的分界：**只要够得着服务器一次，
    ///    就重新开始计时** —— 地铁里断 3 分钟再连上，不会被当成破解版。
    private func noteServerHit() {
        reachedServer = true
        if consecutiveMisses != 0 { consecutiveMisses = 0 }
        setOutageStart(nil)
        if unreachable { unreachable = false }
    }

    /// ❌ 这一次没够着服务器（超时 / DNS 失败 / 连接被拒 / 地址拼不出）。
    ///
    /// 从**第一次 miss** 起算时间窗，连续够不着累计到 `offlineLockAfter` 就判"异常离线" → 锁。
    /// 用"时间"而不是"次数"判定：刷新有好几个来源（根视图 30 秒 / 回前台 / 门禁页 5 秒），
    /// 次数会被频率带偏，时间窗不会。
    private func noteServerMiss() {
        consecutiveMisses += 1
        let wall = Date().timeIntervalSince1970
        var start = outageStart()
        if start == nil {
            start = wall
            setOutageStart(wall)          // ⭐ 落盘：强杀 / 重启不会把时间窗清零
        }
        let elapsed = wall - (start ?? wall)
        if !unreachable && elapsed >= offlineLockAfter {
            unreachable = true
            BlackBox.log("⚠️ 连续 \(Int(elapsed))s 够不着服务器 → 锁（防破解版屏蔽服务器）")
        }
    }

    /// 连续够不着服务器的起点（存 UserDefaults）。没有 = nil。
    private func outageStart() -> TimeInterval? {
        let v = UserDefaults.standard.double(forKey: Self.outageKey)
        return v > 0 ? v : nil
    }

    /// 写 / 清连续够不着服务器的起点。
    private func setOutageStart(_ value: TimeInterval?) {
        let d = UserDefaults.standard
        if let value { d.set(value, forKey: Self.outageKey) }
        else { d.removeObject(forKey: Self.outageKey) }
    }

    /// 用服务端下发的 `offline_grace` 更新阈值（**钳位到 [60, 3600]**）。
    ///
    /// ⚠️ 必须钳位：这个值一旦被下发成 0 / 负数，所有人一断网立刻锁 ——
    ///    等于自己把服务搞挂。服务端没回这个字段 → 保持默认 300 不动。
    private func applyOfflineGrace(_ seconds: Int?) {
        guard let seconds else { return }
        offlineLockAfter = min(max(TimeInterval(seconds),
                                   Self.offlineGraceMin), Self.offlineGraceMax)
    }

    /// Unix 秒 → `M月d日 HH:mm`（本地时区）。只用于界面显示。
    static func dateText(_ epoch: Int) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - 账号还在不在

    /// 问一句「我这个账号还在不在」。
    ///
    /// ## 用户要的（2026-09-26）
    /// 「如果我这边后台把这个用户删掉了之后，手机那边也是过期了，**但是数据还在**」。
    ///
    /// 所以：账号被删 → **退回未授权那一屏**（要用新账号重新绑一次），
    /// 但**本地数据一条都不删** —— 人设、聊天记录、记忆、图片全留着。
    /// 删账号是"不给用了"，不是"把你的东西抹掉"。
    ///
    /// ⚠️ 四种情况必须分清，**只有第一种才吊销**：
    /// - 401 / 403 → 账号真没了（或登录态失效）→ 吊销
    /// - 网络错误 / 超时 → **什么都不做**。断个网就把人踢出去，那是灾难
    /// - 没登录过账号 → 不管（那种是"绑过码但没在 App 里登录"，没法查）
    /// - 服务器返回 5xx → 什么都不做（服务器自己出问题不算用户的错）
    func verifyAccountStillThere() async {
        let token = AppSettings.shared.accountToken
        guard !token.isEmpty else { return }
        guard !verifying else { return }
        verifying = true
        defer { verifying = false }

        var base = AppSettings.shared.accountServerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, let url = URL(string: base + "/api/me") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 必须是新的 —— 缓存里那个 200 会让"已经删了"永远查不出来
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 {
                revokeBecauseAccountGone()
            }
        } catch {
            // 断网/超时 —— **绝不吊销**。这一条比什么都重要。
            return
        }
    }

    /// 账号已经在后台被删掉了：退回未授权，但**只动授权标记**。
    private func revokeBecauseAccountGone() {
        guard authorized else { return }
        let settings = AppSettings.shared
        authorized = false
        account = nil
        settings.deviceAuthorized = false
        settings.deviceAuthorizedAccount = ""
        // 账号都没了 → 体验窗口也一并清掉，别留个"半死"状态（本地数据照旧不动）。
        trialExpiresAt = nil
        trialOver = false
        TrialClock.clear()
        // ⚠️ 下面这些**一个都不许碰**：PersonaStore / ChatStore / MemoryStore /
        // MomentStore / 头像和背景图文件。用户说得清清楚楚：「过期了，但是数据还在」。
        BlackBox.log("⚠️ 账号已不存在 → 退回未授权（本地数据原样保留）")
    }

    // MARK: - 零件

    private func lookupURL() -> URL? {
        var base = AppSettings.shared.accountServerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        // 设备码本来就是 `AEVIS` + 12 位十六进制，没有一个字符需要转义。
        // 这里仍然滤一道：万一以后形态变了，别让奇怪字符把 URL 拼歪。
        // ⚠️ 不用 `CharacterSet.alphanumerics` —— 那是 Unicode 的，
        // 它会把中文当成"可以留着"，等于没编码（R22 就是为这个立的）。
        let code = DeviceIdentity.canonical.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard !code.isEmpty else { return nil }
        return URL(string: base + "/api/device/lookup?device_id=" + code)
    }

    /// 界面上那行状态。**三种情况要分开说**，别混成一句"失败了"：
    /// 还没查 / 连不上 / 确实还没绑。
    var statusLine: String {
        if trialOver {
            return "这次的一天体验已经到期了。续费后就能继续用，本地数据都在。"
        }
        if unreachable {
            return "连不上服务器（已经试了很久了）。连上网就会自动恢复，数据都在。"
        }
        if authorized {
            if let exp = trialExpiresAt {
                return "一天体验中，到期时间 " + Self.dateText(exp) + "。"
            }
            return account.map { "已经授权了，绑在 \($0) 上。" } ?? "已经授权了。"
        }
        if checking && !reachedServer { return "正在查询授权状态…" }
        if let problem { return problem }
        return "还没有授权 —— 上面这个设备码还没有绑到任何账号上。"
    }
}
