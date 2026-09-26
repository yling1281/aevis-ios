import Foundation

/// 把崩溃现场传给服务器 —— 用户在群里报一个错误码，智能客服就能查到。
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
///
/// ## 失败不重试
/// 传不上去就算了：本机那份一直在，用户还能自己复制发出来。
/// 为一个诊断功能引入重试队列，只会给一个正在被闪退困扰的 App 添乱。
enum DiagUploader {

    /// 传这次崩溃现场。**fire-and-forget**。
    static func uploadCrashIfNeeded() async {
        guard BlackBox.crashedLastRun else { return }
        let code = BlackBox.crashCode

        // 同一台设备、同一个码，一天只传一次 ——
        // 用户可能反复闪退反复打开，不挡的话后台会被同一条刷满（count 反而看不出真实人数）。
        let key = "aevis.diag.uploaded." + code
        let stamp = Date().timeIntervalSince1970
        if stamp - UserDefaults.standard.double(forKey: key) < 86_400 { return }

        let base = AppSettings.shared.accountServerURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty, let url = URL(string: base + "/api/diag") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": code,
            "device": DeviceIdentity.pretty,
            "version": "\(Diagnostics.appVersion) (\(Diagnostics.commit))",
            "os": Diagnostics.osVersion,
            "machine": Diagnostics.machine,
            "signed": Diagnostics.isSigned,
            "body": BlackBox.report(),
        ])
        guard request.httpBody != nil else { return }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                UserDefaults.standard.set(stamp, forKey: key)
                BlackBox.log("崩溃现场已上报 \(code)")
            } else {
                BlackBox.failure("崩溃上报失败", url: url.absoluteString, status: status)
            }
        } catch {
            BlackBox.failure("崩溃上报连不上", url: url.absoluteString,
                             detail: error.localizedDescription)
        }
    }

    /// 用户自己点「发给客服」时走这条 —— **当场传一次，不管去重**。
    /// 他主动要反馈，就该立刻出现在后台，而不是等到明天。
    static func uploadNow() async {
        guard let base = URL(string: AppSettings.shared.accountServerURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/diag")
        else { return }
        var request = URLRequest(url: base)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "code": BlackBox.crashedLastRun ? BlackBox.crashCode : "MANUAL-\(Int(Date().timeIntervalSince1970))",
            "device": DeviceIdentity.pretty,
            "version": "\(Diagnostics.appVersion) (\(Diagnostics.commit))",
            "os": Diagnostics.osVersion,
            "machine": Diagnostics.machine,
            "signed": Diagnostics.isSigned,
            "body": BlackBox.report(),
        ])
        guard request.httpBody != nil else { return }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                BlackBox.log("已手动上报诊断")
            } else {
                BlackBox.failure("手动上报失败", url: base.absoluteString, status: status)
            }
        } catch {
            BlackBox.failure("手动上报连不上", url: base.absoluteString,
                             detail: error.localizedDescription)
        }
    }
}
