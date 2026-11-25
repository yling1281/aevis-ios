import Foundation
import SwiftUI
import UIKit

/// App 更新检查（2026-11-22 新版重写工程，从旧工程 `Core/AppUpdate.swift` 搬来并精简）
///
/// 只做「配置与文案」层面的热更：最新版本号、强制标记、更新文案、IPA/OTA 地址。
/// iOS 禁止动态下发可执行代码，Swift 代码不可热更（App Store 审核指南 3.3.2）。
/// 服务端 `force=1` 时弹窗不可关闭，用户必须更新后才能继续使用 App。
///
/// 安装的现实边界：沙盒内 App 无法自我安装 IPA。
/// - `installHint=ota`：走 `itms-services://` 跳系统安装页；
/// - `installHint=ipa_manual`：只能下载到「文件」再交由签名工具安装，
///   界面文案必须如实说明，不能让用户以为点一下就能装好。
@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    /// 4-4 后端（与小程序同源）
    private let base = "https://aevis.cn/prod-api/aevis"

    @Published var latest: UpdateInfo?
    @Published var dismissed = false
    @Published var checking = false

    private var lastCheck: Date = .distantPast
    /// 节流窗口（2026-11-24 从 6 小时改为 30 分钟）。
    /// 原来 6 小时会让「强制更新」在用户 6 小时内查过的场景下**根本不查 → 不弹**，
    /// 这正是「强更不弹」的根因。`/v1/app/update` 只是个 GET，30 分钟足够省，又不耽误强更。
    /// 注意 `lastCheck` 是**内存态**（不持久化），每次冷启动都是 `.distantPast`，
    /// 所以冷启动必然通过节流、每次都查。
    private let checkInterval: TimeInterval = 30 * 60   // 30 分钟

    private init() {}

    // MARK: - 模型

    struct UpdateInfo: Equatable {
        let current: String
        let latest: String
        let force: Bool
        let notes: String
        let ipaURL: String
        let otaURL: String
        let installHint: String

        var hasOTA: Bool { installHint == "ota" && !otaURL.isEmpty }
    }

    // MARK: - 检测

    /// 是否该弹窗：低于 latest 或强制更新，且用户本次未忽略。
    var shouldPrompt: Bool {
        guard let info = latest else { return false }
        if info.force { return true }          // 强制更新无视「稍后」
        return !dismissed
    }

    /// 启动 / 回前台时调用。带 30 分钟短节流，避免频繁请求；`force=true` 可无视节流（冷启动用）。
    func checkIfNeeded(force: Bool = false) async {
        if !force, Date().timeIntervalSince(lastCheck) < checkInterval { return }
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        var comps = URLComponents(string: base + "/v1/app/update")
        comps?.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: ver),
        ]
        guard let url = comps?.url else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let payload = (json["data"] as? [String: Any]) ?? [:]
            lastCheck = Date()

            // 服务端布尔兼容（2026-11-25）：`update` / `force` 不能只按 `as? Bool` 读。
            // 线上实测这两个字段是真 bool，但 RuoYi 侧其他接口有把布尔序列化成 1/0 的先例，
            // 强更标记一旦被读成 false，用户就直接绕过门禁了 —— 这里一律走宽松解析。
            guard Self.boolValue(payload["update"]) else {
                latest = nil
                return
            }
            latest = UpdateInfo(
                current: (payload["current"] as? String) ?? ver,
                latest: (payload["latest"] as? String) ?? "",
                force: Self.boolValue(payload["force"]),
                notes: (payload["notes"] as? String) ?? "",
                ipaURL: (payload["ipaUrl"] as? String) ?? "",
                otaURL: (payload["otaUrl"] as? String) ?? "",
                installHint: (payload["installHint"] as? String) ?? "ipa_manual"
            )
            dismissed = false
        } catch {
            // 网络失败静默：更新检测不该阻塞使用
        }
    }

    // MARK: - 动作

    /// 宽松布尔解析：真 bool / `1`-`0` / `"true"`-`"false"` 都认。
    ///
    /// 只用于 `update` / `force` 这两个**门禁**字段。它们读错的后果不对称：
    /// 读成 false = 用户绕过强制更新门禁继续用旧版；读成 true 最多多弹一次窗。
    /// 所以这里宁可宽，不可严。
    static func boolValue(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return t == "true" || t == "1" || t == "yes"
        }
        return false
    }

    /// 打开安装入口。OTA 优先；否则把 IPA 交给系统下载（用户再到「文件」里签名安装）。
    func openInstall() {
        guard let info = latest else { return }
        if info.hasOTA, let u = URL(string: info.otaURL) {
            UIApplication.shared.open(u)
            return
        }
        if let u = URL(string: info.ipaURL), !info.ipaURL.isEmpty {
            UIApplication.shared.open(u)
        }
    }

    func dismiss() { dismissed = true }
}
