import ActivityKit
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 她回消息时，把这句话送上**灵动岛**（Live Activity）。
///
/// ## 设计前提（别改，这是这个功能能不能成立的全部依据）
/// 侧载包**没有 APNs 密钥**，所以：
///   · 起一个 Live Activity **必须 App 在前台**（苹果明确限制，绕不过去）；
///   · 起完之后**后台可以更新**（文档明确允许）；
///   · 带 `alertConfiguration` 更新 → **灵动岛展开 + 出声** = 老板要的「弹窗」。
/// App 后台是活的（见 `SilentKeeper`），所以「前台挂机 + 后台更新」这条路成立。
///
/// ## 行为（老板已拍板）
/// - **默认挂机**：活动一直挂着（灵动岛角落一个不起眼的小标记），
///   到 8 小时上限 / 回前台时自动重开。
/// - 设置里能关（默认开）；远端配置当 kill switch 叠加在本地设置之上。
@MainActor
final class LiveIslandCenter {
    static let shared = LiveIslandCenter()

    /// 活动最多挂这么久就重开 —— 系统的 Live Activity 有 8 小时硬上限，
    /// 留点余量，别卡在边界上。
    private static let maxAge: TimeInterval = 7 * 3600

    /// 送进灵动岛的那句话最长留多少字。**在意层截断** —— 她整段话可能很长，
    /// 别把整段塞进活动状态（状态要序列化、还走系统 IPC）。
    private static let maxChars = 80

    private var activity: Activity<AevisMessageAttributes>?

    private init() {}

    // MARK: - 开关

    /// 到底干不干活：**本地设置开着 && 远端没关** 才算开。
    ///
    /// ⚠️ 远端配置**不能**替用户打开他关掉的东西 —— 它只能当 kill switch
    ///    （谁都能关、谁都不能开）。
    private var enabled: Bool {
        guard AppSettings.shared.liveIsland else { return false }
        return RemoteConfig.shared.bool("liveIsland", default: true)
    }

    // MARK: - 挂机态

    /// **App 回到前台时调**：把挂机态的活动接上。
    ///
    /// 整段 try/catch —— 起不来就当没这回事，**绝不影响别的功能**。
    func sync() {
        guard enabled else {
            end()
            return
        }
        // 用户在系统的「实时活动」总开关里关了 → 什么也不做
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // App 重启后内存里的引用没了，但活动可能还在 —— 认领系统里还活着的那个。
        if activity == nil, let existing = Activity<AevisMessageAttributes>.activities.first {
            activity = existing
        }
        if let live = activity,
           Date().timeIntervalSince(live.attributes.startedAt) < Self.maxAge {
            return    // 还年轻 → 什么都不做
        }
        // 太老 / 还没有 → 结束旧的，重开一个挂机态
        let stale = activity
        activity = nil
        Task {
            if let stale = stale {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
            self.requestIdle()
        }
    }

    /// 起一个**挂机态**的活动（`text` 为空）。
    private func requestIdle() {
        guard activity == nil else { return }
        do {
            let attributes = AevisMessageAttributes(startedAt: Date())
            let state = AevisMessageAttributes.ContentState(name: "", text: "", at: Date())
            let content = ActivityContent(state: state, staleDate: nil)
            activity = try Activity.request(attributes: attributes,
                                            content: content,
                                            pushType: nil)
        } catch {
            // 起不来就安静放弃（苹果不给起 / 用户关了总开关 / 超了活动数量上限…）
            activity = nil
        }
    }

    // MARK: - 有消息

    /// 她回消息时调。`name` 是她叫什么，`text` 是她这一整段话。
    func push(name: String, text: String) {
        guard enabled else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let said = Self.clip(text)
        guard !said.isEmpty else { return }
        let herName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        let state = AevisMessageAttributes.ContentState(name: herName, text: said, at: Date())
        let content = ActivityContent(state: state, staleDate: nil)

        // 前台：**静默更新**（人正看着聊天，再弹一下就是打扰）。
        // 后台：**带 alert 更新** → 灵动岛展开 + 响一声 —— 这才是老板要的「弹窗」。
        //
        // 🔴 注意这里**不能**写 `sound: foreground ? nil : .default`：
        //    `AlertConfiguration.init(title:body:sound:)` 的 `sound:` 是**非可选**的
        //    （签名就是 `sound: AlertConfiguration.AlertSound`，**没有 nil 这一档**），
        //    给它 nil 直接编译失败 —— 本地没 Xcode，这个错会一路拖到 CI 才暴露。
        //    「前台不出声」的正确实现是**整条 alertConfiguration 传 nil**（见下面的 update）。
        let foreground = isForeground()
        let alert = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: herName.isEmpty ? "她" : herName),
            body: LocalizedStringResource(stringLiteral: said),
            sound: .default
        )

        Task {
            // 活动不在（被系统收了 / 还没挂上）→ 先补一个再更新；补不上就安静放弃。
            if self.activity == nil,
               let existing = Activity<AevisMessageAttributes>.activities.first {
                self.activity = existing
            }
            if self.activity == nil {
                self.requestIdle()
            }
            guard let live = self.activity else { return }
            await live.update(content, alertConfiguration: foreground ? nil : alert)
        }
    }

    // MARK: - 收尾

    /// 把活动结束掉（开关关掉 / 用户不想挂了）。
    func end() {
        let live = activity ?? Activity<AevisMessageAttributes>.activities.first
        activity = nil
        guard let live = live else { return }
        Task { await live.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: - 零件

    /// App 现在是不是前台。用 `UIApplication` 判断，**要 `#if canImport(UIKit)` 保护**
    ///（widget / 别的平台没有 UIKit）。
    private func isForeground() -> Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// 把整段话压成一行、截到 `maxChars`。
    private static func clip(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= maxChars { return flat }
        return String(flat.prefix(maxChars)) + "…"
    }
}
