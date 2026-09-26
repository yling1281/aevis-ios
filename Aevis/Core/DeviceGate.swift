// ⚠️ 用 SwiftUI 而不是 Foundation：`ObservableObject` / `@Published` 是 Combine 的东西，
// 而本机没有 Xcode，少一个 import 就要白烧一轮 CI 才发现。
import SwiftUI

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

        guard let url = lookupURL() else {
            problem = "设备码拼不出查询地址，重装一次 App 试试。"
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
            reachedServer = true

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
                // 已经授权过就别再 grant 一遍了：那个方法会往 UserDefaults 写东西，
                // 而现在是**隔一会儿就查一次**，没必要每次都写。
                if !authorized { grant(account: json["account"] as? String) }
            } else {
                // 还没绑 —— 这是最正常的状态，不是错误
                problem = nil
            }
        } catch {
            // 断网/超时。**不撤销已有授权**，只说"这次没查到"。
            problem = "没连上服务器（\(error.localizedDescription)）"
        }
    }

    // MARK: - 授权通过

    /// 记下"这台设备通过了"。**写入本机，之后就再也不查了。**
    func grant(account masked: String?) {
        let settings = AppSettings.shared
        authorized = true
        account = masked
        problem = nil
        reachedServer = true
        settings.deviceAuthorized = true
        settings.deviceAuthorizedAccount = masked ?? ""
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
        if authorized {
            return account.map { "已经授权了，绑在 \($0) 上。" } ?? "已经授权了。"
        }
        if checking && !reachedServer { return "正在查询授权状态…" }
        if let problem { return problem }
        return "还没有授权 —— 上面这个设备码还没有绑到任何账号上。"
    }
}
