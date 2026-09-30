import Foundation

/// 把崩溃 / 卡死现场传给服务器 —— 用户在群里报一个错误码，智能客服就能查到。
///
/// ## 为什么要有它
/// 用户 2026-09-26 的口径：「把错误码发给它，它也能给你反馈，
/// 如果这个问题是软件的问题，就是反馈到我的后台」。
/// 光在本机留一个码没用 —— **码得跟现场一起落到后台，客服才查得动**。
///
/// ## 一条底线
/// **只传诊断信息**：版本、机型、系统、错误码、最后几十步操作。
/// **不传人设、不传聊天记录、不传记忆** —— App 对外宣称的「内容只在本机」依然成立。
/// 黑匣子本来就没记过聊天内容，这里只是把它搬上去。
/// ⚠️ 上传前会再过一道 `sanitize`：本地黑匣子**保留**聊天（用户要求），
///    脱敏只在上传那一刻做。
///
/// ## 失败不重试（卡死补传除外）
/// 传不上去就算了：本机那份一直在，用户还能自己复制发出来。
/// 为一个诊断功能引入重试队列，只会给一个正在被闪退困扰的 App 添乱。
enum DiagUploader {

    // MARK: - 上传前脱敏

    /// 上传前把正文里会泄隐私的行剔掉，只留诊断时间线：
    /// 页面 → 点击/动作 → `[tool]` → `[freeze]` → 网络 → 启动。
    /// **本地黑匣子保留聊天**（用户明确要求），脱敏只在上传这一刻做 ——
    /// 服务器上永远见不到聊天 / 人设 / 记忆的原文。
    ///
    /// 白名单之外的一整行都丢掉（尤其 `💬` 开头的聊天行）。
    /// 行首时间戳 `HH:mm:ss `。只剥**真正的时间戳前缀** ——
    /// `[freeze] 主线程无响应 ≥5s` 这种没时间戳的字面量行不能切。
    private static let timestampRegex = try? NSRegularExpression(
        pattern: "^\\d{2}:\\d{2}:\\d{2}\\s")

    static func sanitize(_ body: String) -> String {
        let keepPrefixes = [
            "⇢ ", "⇠ ",        // 页面（进 / 出）
            "⊙ ",              // 点击
            "▸ ",              // 动作（step）
            "[tool]",          // 工具调用
            "[freeze]",        // 卡死
            "· ",              // 网络成功
            "❗️",              // 网络失败
            "App 启动",        // 会话起点
            "— 进后台",        // 正常进后台
        ]
        return body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let stripped = line.trimmingCharacters(in: .whitespaces)
                var after = stripped
                // 只剥真正的 `HH:mm:ss ` 前缀；没匹配到就原样用（比如 [freeze] 行）。
                if let regex = timestampRegex,
                   let match = regex.firstMatch(
                       in: stripped,
                       range: NSRange(stripped.startIndex..., in: stripped)),
                   match.range.location == 0 {
                    let start = stripped.index(stripped.startIndex,
                                               offsetBy: match.range.length)
                    after = String(stripped[start...])
                }
                return keepPrefixes.contains { after.hasPrefix($0) }
            }
            .joined(separator: "\n")
    }

    // MARK: - 崩溃

    /// 传这次崩溃现场。**fire-and-forget**。
    static func uploadCrashIfNeeded() async {
        guard BlackBox.crashedLastRun else { return }

        // ⚠️ **模拟器不传**。CI 截图那一步会反复起 App、又直接 kill 掉，
        // 而"没走到 `markCleanExit`"在那种情况下全被记成崩溃 ——
        // 2026-09-26 后台一晚上被刷了三十多条假报告，把真现场全淹了。
        // 用 `targetEnvironment(simulator)` 而不是启动参数：截图脚本的参数在
        // workflow 里，而 workflow 我推不上去（连接器没有 workflows 权限）。
        #if targetEnvironment(simulator)
        return
        #endif

        let code = BlackBox.crashCode

        // 同一台设备、同一个码，一天只传一次 ——
        // 用户可能反复闪退反复打开，不挡的话后台会被同一条刷满（count 反而看不出真实人数）。
        let key = "aevis.diag.uploaded." + code
        let stamp = Date().timeIntervalSince1970
        if stamp - UserDefaults.standard.double(forKey: key) < 86_400 { return }

        let status = await postDiag(type: "crash", code: code,
                                    body: sanitize(BlackBox.report()))
        if (200..<300).contains(status) {
            UserDefaults.standard.set(stamp, forKey: key)
            BlackBox.log("崩溃现场已上报 \(code)")
        } else if status < 0 {
            BlackBox.failure("崩溃上报连不上")
        } else {
            BlackBox.failure("崩溃上报失败", status: status)
        }
    }

    /// 用户自己点「发给客服」时走这条 —— **当场传一次，不管去重**。
    /// 他主动要反馈，就该立刻出现在后台，而不是等到明天。
    static func uploadNow() async {
        let code = BlackBox.crashedLastRun ? BlackBox.crashCode
                    : "MANUAL-\(Int(Date().timeIntervalSince1970))"
        let status = await postDiag(type: "crash", code: code,
                                    body: sanitize(BlackBox.report()))
        if (200..<300).contains(status) {
            BlackBox.log("已手动上报诊断")
        } else if status < 0 {
            BlackBox.failure("手动上报连不上")
        } else {
            BlackBox.failure("手动上报失败", status: status)
        }
    }

    // MARK: - 卡死

    /// 卡死那一刻的**轻量**上报（`Watchdog` 检测到就 fire-and-forget 调这里）。
    /// ⚠️ **不碰黑匣子锁** —— 主线程可能正卡在锁上，这里再取锁等于陪葬。
    static func reportFreezeLight() async {
        #if targetEnvironment(simulator)
        return
        #endif
        _ = await postDiag(type: "freeze", code: BlackBox.freezeCode,
                           body: "[freeze] 主线程无响应 ≥5s")
    }

    /// 下次启动时补传**富 body**（黑匣子最后那几十步）并清标记。
    /// 卡死那一刻不敢读黑匣子，这里 App 已经正常起来，可以放心读。
    /// ⚠️ 只在**异常退出**（`crashedLastRun`）时补传富 body：正常退出时 `markCleanExit`
    ///    已经把 freezePending 清掉了；而且只有异常退出，`lastCrashLines` 才是
    ///    「卡死前那几十步」的可靠快照（正常退出会混入陈旧/无关旧行）。
    static func uploadFreezeIfNeeded() async {
        #if targetEnvironment(simulator)
        return
        #endif
        guard Watchdog.hasFreezePending(), BlackBox.crashedLastRun else { return }

        var parts = ["[freeze] 主线程无响应 ≥5s"]
        let lines = BlackBox.lastCrashLines
        if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }

        let status = await postDiag(type: "freeze", code: BlackBox.freezeCode,
                                    body: sanitize(parts.joined(separator: "\n")))
        if (200..<300).contains(status) {
            Watchdog.clearFreezePending()
            BlackBox.log("卡死现场已补传 \(BlackBox.freezeCode)")
        } else if status < 0 {
            BlackBox.failure("卡死补传连不上")
        } else {
            BlackBox.failure("卡死补传失败", status: status)
        }
    }

    // MARK: - 公共：打一次 `/api/diag`

    /// 打一次 `POST /api/diag`。返回 HTTP 状态码；网络层失败返回 -1。
    /// ⚠️ 这里**不写黑匣子** —— freeze 那条路必须在"不取锁"的前提下也能安全调用。
    private static func postDiag(type: String, code: String, body: String) async -> Int {
        let base = AppSettings.shared.accountServerURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty, let url = URL(string: base + "/api/diag") else { return -1 }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "type": type,
            "code": code,
            "device": DeviceIdentity.pretty,
            "version": "\(Diagnostics.appVersion) (\(Diagnostics.commit))",
            "os": Diagnostics.osVersion,
            "machine": Diagnostics.machine,
            "signed": Diagnostics.isSigned,
            "body": body,
        ])
        guard request.httpBody != nil else { return -1 }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
