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
    private let checkInterval: TimeInterval = 6 * 3600   // 6 小时

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

    /// 启动 / 回前台时调用。带 6 小时节流，避免频繁请求。
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

            guard (payload["update"] as? Bool) == true else {
                latest = nil
                return
            }
            latest = UpdateInfo(
                current: (payload["current"] as? String) ?? ver,
                latest: (payload["latest"] as? String) ?? "",
                force: (payload["force"] as? Bool) ?? false,
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
