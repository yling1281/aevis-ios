import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 聊天记录自动同步到百度网盘。
///
/// ## 老板要的三件事（2026-10-03 原话）
/// 「每次退出这个 App 就把聊天记录备份到百度网盘，登录其他的设备就从网盘把聊天记录
///   恢复到本机，还有实时同步 —— 每发一句话就把聊天记录自动同步到百度网盘。」
///
/// 对应到这里就是三下：
/// | 老板说的 | 这里的方法 | 什么时候触发 |
/// |---|---|---|
/// | 实时同步 | `noteChanged()` | `ChatStore` 每落一条消息（去抖几秒） |
/// | 退出时备份 | `syncNow(reason:)` | App 退到后台 / 被杀之前的那个时机 |
/// | 换设备恢复 | `autoRestoreIfNewDevice()` | App 启动，并且本机还是空的 |
///
/// ## 🔴 三条纪律（不这么做就会出事故）
/// 1. **一律 `@MainActor`**。要读各 Store 的 `@Published`，在别的线程读会让
///    SwiftUI 收到跨线程通知 —— **iOS 26 上会硬崩**（`BackupService.makeBackup` 的注释里写着）。
/// 2. **同一时刻只允许一个上传**（`busy`）。去抖之后连着触发两次是常态，
///    两个几 MB 的分片上传撞一起，网盘那边会限流，我们自己的状态也会乱跳。
/// 3. **失败不弹窗，只记状态**。这是后台行为，用户没点任何东西 ——
///    为它弹框是骚扰。这一句没传上去，下一句话、或者下次退出时还会再传一次。
///
/// ## ⚠️ 传的是「轻包」（只有文字）
/// 每说一句话就传一次，所以包里**不含头像和朋友圈配图**（那是几 MB 的原图）。
/// 见 `BackupService.Kind`。手动那个「备份到网盘」按钮仍然传完整包。
///
/// ## ⚠️ 自动恢复的门槛
/// **只有本机还是空的（一个人都没有）才自动恢复。**
/// 本地有数据还去恢复，等于把用户正在用的聊天记录覆盖掉 —— 那是灾难，
/// 不是功能。所以这条门槛写死在 `autoRestoreIfNewDevice()` 里，不许放宽。
@MainActor
final class AutoSync: ObservableObject {

    static let shared = AutoSync()

    enum State: Equatable {
        case off                     // 没登录 / 没连网盘 / 用户关了开关 —— 什么都不做
        case idle
        case syncing(String)         // 正在传什么
        case failed(String)          // 上一次为什么没成（给人看的一句话）

        var text: String {
            switch self {
            case .off: return "没在同步"
            case .idle: return "已同步"
            case .syncing(let what): return "正在同步\(what)…"
            case .failed(let why): return "同步失败：\(why)"
            }
        }
    }

    @Published private(set) var state: State = .idle
    /// 上一次成功的时刻（界面上显示"刚刚同步过"）。
    @Published private(set) var lastSuccess: Date?

    /// 上次成功同步的时刻存在这里的键。
    ///
    /// ⚠️ **为什么非要落盘**：不落的话每次冷启动 `lastSuccess` 都是 nil，
    ///    界面上永远显示"还没同步过"；更要紧的是 `minGap` / `backgroundGap`
    ///    的节流会**随着每次冷启动失效** —— 用户来回切 App 就会反复上传同一份包。
    private static let lastSyncKey = "aevis.autoSync.lastSuccess"

    /// 说一句话之后**等这么久**再传。
    ///
    /// ⚠️ **别调成 0**：ta一次回复会连着落好几条（打字机式的富文本、或者连着发两条），
    ///    那就是每落一条传一个包。等齐了只传一次。
    private let quiet: TimeInterval = 6
    /// 两次自动同步之间最少隔这么久 —— 兜住"聊得很密"的情况。
    private let minGap: TimeInterval = 20
    /// 退到后台时，距上次成功同步不到这么久就不用再传（切来切去别狂传）。
    private let backgroundGap: TimeInterval = 45

    private var started = false
    private var pending: Task<Void, Never>?
    private var busy = false
    private var lastAttempt = Date.distantPast

    private init() {
        // 上次成功同步的时刻（跨启动保留 —— 否则节流每次冷启动都归零）。
        let stamp = UserDefaults.standard.double(forKey: Self.lastSyncKey)
        if stamp > 0 {
            lastSuccess = Date(timeIntervalSince1970: stamp)
            // ⚠️ 把节流的起点也接上。不接的话"冷启动 → 马上切后台"这一下
            //    会无视 `backgroundGap` 直接传一份 —— 用户切来切去就是反复传同一份包。
            lastAttempt = Date(timeIntervalSince1970: stamp)
        }
    }

    // MARK: - 开关

    /// App 启动时叫一次（**幂等**）。
    ///
    /// 为什么在这里挂监听而不是各个发送点：发送点有十几处（打字、语音、转账、红包、
    /// ta主动发消息…），漏一个就是"那种情况下不同步" —— 而且**只在特定路径下漏**，
    /// 极难查。挂在 `ChatStore.append` 上就一网打尽。
    func start() {
        guard !started else { return }
        started = true
        ChatStore.shared.addAppendListener { [weak self] _message, _owner in
            // ⚠️ 落消息这一下是在主线程上的（`ChatStore.append` 由界面路径调用），
            //    但**别假设** —— 用 `Task { @MainActor }` 兜一下，代价几乎为零。
            //    ⚠️ 也**别**改成直接同步调用：`AutoSync` 是 `@MainActor`，
            //       而这个闭包是 `nonisolated` 的，同步调会编译不过。
            Task { @MainActor in self?.noteChanged() }
        }
        refresh()
    }

    /// 现在有没有条件同步（登录 + 连过网盘 + 开关是开的）。
    private var eligible: Bool {
        AppSettings.shared.autoSyncEnabled
            && AccountService.shared.isSignedIn
            && BaiduPanClient.shared.isAuthorized
    }

    /// 重新算一下「现在能不能同步」。
    ///
    /// 为什么要单独有这么一下：条件是**会变的**，而且变化的时候没有消息落下来 ——
    /// 用户刚在设置页点完「连接百度网盘」，或者刚登录完账号。
    /// 不主动刷一次的话，状态行会一直停在"没在同步"，用户以为坏了。
    func refresh() {
        guard !busy else { return }
        guard eligible else {
            state = .off
            return
        }
        // ⚠️ 只在"原来是不能同步"的时候改状态。
        //    别无条件写 `state = .idle` —— 那会把上一次的失败提示擦掉，
        //    用户刚看到"同步失败：xxx"，切个前台就变成"已同步"，等于骗人。
        if state == .off { state = .idle }
    }

    // MARK: - ① 实时同步

    /// 刚多了一条消息。**去抖**之后再传 —— 连着落好几条只传一次。
    func noteChanged() {
        guard eligible else {
            state = .off
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.quiet * 1_000_000_000))
            if Task.isCancelled { return }
            await self.upload(reason: "聊天记录", force: false)
        }
    }

    // MARK: - ② 退出 / 切后台

    /// 立刻同步一次（不等去抖）。
    ///
    /// ⚠️ iOS **不给我们"用户点了退出"这个事件** —— 系统杀 App 之前只保证
    ///    给一小段后台时间。所以"每次退出 App 就备份"实际落在
    ///    **App 退到后台**那一刻（`scenePhase` 变 `.background`）。
    ///    对用户来说效果一样：他按下 home 键 / 划走，记录就已经在网盘上了。
    ///
    /// ⚠️⚠️ **光靠 `scenePhase` 是不够的**：退到后台之后系统只给几秒钟，
    ///    一份几十 KB 的包加上"取 token + 建目录 + 上传"的几轮往返，
    ///    网络稍差就传不完、被当场挂起 —— 用户下次打开发现"上次那条没同步"。
    ///    所以这里额外**向系统要一段后台时间**（`beginExtraTime()`）。
    ///    见 `extraTime` 那段注释，里面写了要不到会怎样。
    func syncNow(reason: String) {
        guard eligible else {
            state = .off
            return
        }
        // 刚传过就别再传（切来切去会很频繁）
        if Date().timeIntervalSince(lastAttempt) < backgroundGap, !busy {
            return
        }
        beginExtraTime()
        pending?.cancel()
        pending = Task { [weak self] in
            await self?.upload(reason: reason, force: true)
        }
    }

    // MARK: - 上传（唯一真正动手的地方）

    private func upload(reason: String, force: Bool) async {
        defer { endExtraTime() }
        guard eligible else {
            state = .off
            return
        }
        guard !busy else { return }                 // 🔴 同一时刻只允许一个
        if !force, Date().timeIntervalSince(lastAttempt) < minGap { return }
        busy = true
        lastAttempt = Date()
        state = .syncing(reason)
        defer { busy = false }

        do {
            _ = try await BackupService.shared.backupToPan(kind: .live)
            lastSuccess = Date()
            state = .idle
            UserDefaults.standard.set(lastSuccess?.timeIntervalSince1970 ?? 0, forKey: Self.lastSyncKey)
            BlackBox.log("自动同步完成（\(reason)）")
        } catch {
            // ⚠️ **不弹窗**。见类型注释第 3 条。
            state = .failed(Self.short(error))
            BlackBox.log("自动同步失败（\(reason)）：\(error.localizedDescription)")
        }
    }

    // MARK: - 后台时间
    //
    // 🔴 为什么需要这个：iOS 上「退到后台」之后 App 只剩**几秒**就要被挂起。
    //    而那几秒里我们要做：取网盘 token（可能要续期，一次网络往返）→
    //    确认目录在 → 分片上传。网络稍差就注定被掐死在半路。
    //    `beginBackgroundTask` 是系统给的正规通道 —— 要一段额外时间
    //    （现代 iOS 大约 30 秒），到期前必须 `endBackgroundTask`，否则
    //    系统会认为我们赖着不走，**下次直接不给**，甚至直接杀掉进程。
    //
    // ⚠️ 要不到（系统不给 / 已经超了）**也不是失败** —— 那就退回"几秒钟内能传多少传多少"，
    //    行为跟加这个之前一样。所以这几句全程 `guard`，绝不因为拿不到就报错。
    // ⚠️ 只包住 `force` 那条路（退到后台）。前台实时同步本来就有一整个
    //    App 生命周期可用，用不着占后台额度。

    #if canImport(UIKit)
    private var extraTime: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func beginExtraTime() {
        #if canImport(UIKit)
        guard extraTime == .invalid else { return }
        extraTime = UIApplication.shared.beginBackgroundTask(withName: "aevis.autosync") { [weak self] in
            // 系统来收账了：**必须立刻还**，否则会被当成滥用后台。
            Task { @MainActor in self?.endExtraTime() }
        }
        #endif
    }

    private func endExtraTime() {
        #if canImport(UIKit)
        guard extraTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(extraTime)
        extraTime = .invalid
        #endif
    }

    // MARK: - ③ 换设备自动恢复

    /// 启动时叫一次：**本机还是空的话**，从网盘把最新的那份拉回来。
    ///
    /// 🔴 门槛（不许放宽）：`PersonaStore.shared.contacts.isEmpty` —— 一个人都没有。
    ///    只要本机已经有ta，这个函数**什么都不做**。
    ///    理由：本地有数据还自动恢复 = 把用户正在用的聊天记录覆盖掉。
    ///    换设备时本机必然是空的，所以这条门槛不会挡住正当用途。
    ///
    /// ⚠️ 还需要"连过网盘"。新设备上刚扫码登录完是**没有**网盘授权的 ——
    ///    所以这条路一开始会先去服务器把网盘授权取回来
    ///    （`BaiduPanClient.adoptFromAccount()`；服务器的授权是**按账号**存的，
    ///    跟设备无关 ⇒ 新设备登录同一个账号就自动有）。
    ///
    /// ⚠️ 那条 `adoptFromAccount()` 是**顺手做的**：它失败了也不影响别的 ——
    ///    大不了这次不恢复，用户在设置页点一次「连接百度网盘」照样能恢复。
    @discardableResult
    func autoRestoreIfNewDevice() async -> String? {
        guard AppSettings.shared.autoRestoreEnabled else { return nil }
        guard AccountService.shared.isSignedIn else { return nil }
        // 🔴 只有"空机器"才恢复 —— 见上面的注释。
        //    **放在取网盘授权前面**：这一步是纯本地判断，先过掉它，
        //    本机有数据时连网都不用连（也少一次会写 lastError 的请求）。
        guard PersonaStore.shared.contacts.isEmpty else { return nil }
        // 先看看能不能拿到网盘授权（新设备上这一步就是"自动同步"的钥匙）
        guard await BaiduPanClient.shared.adoptFromAccount() else { return nil }

        state = .syncing("聊天记录")
        do {
            guard let file = await BackupService.shared.newestBackup() else {
                state = .idle                      // 网盘上还没有备份，是正常状态
                return nil
            }
            let what = try await BackupService.shared.restoreFromPan(fsID: file.id)
            state = .idle
            lastSuccess = Date()
            UserDefaults.standard.set(lastSuccess?.timeIntervalSince1970 ?? 0, forKey: Self.lastSyncKey)
            BlackBox.log("换设备自动恢复：\(file.name) → \(what)")
            return what
        } catch {
            state = .failed(Self.short(error))
            BlackBox.log("换设备自动恢复失败：\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 零件

    /// 错误原文截短 —— 界面上那行只有一行位置，网盘返回的原文经常是一整段 JSON。
    private static func short(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let one = text.split(separator: "\n").first.map(String.init) ?? text
        return one.count > 40 ? String(one.prefix(40)) + "…" : one
    }
}
