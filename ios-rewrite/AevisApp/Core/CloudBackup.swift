import Foundation
import SwiftUI

/// 云端自动恢复 / 自动备份（2026-11-17，133）。
///
/// 目标：用户"长时间不打开 app"、"掉签重装"后，只要能登录，聊天记录就还在。
/// 全程静默：失败只 NSLog，不弹窗、不阻塞登录。
final class CloudBackup: ObservableObject {
    static let shared = CloudBackup()
    private init() {}

    /// 设置页显示用："云端已同步 N 条会话"。
    @Published var lastSyncText: String = ""
    /// 最近一次恢复的时间与条数（供设置页展示"上次恢复"）。
    @Published private(set) var lastRestoreAt: Date?
    @Published private(set) var lastRestoreCount: Int = 0

    /// 待用户确认的云端恢复请求（登录后探测到云端有数据时置位，UI 弹框）。
    /// 2026-11-24 用户要求：**先问再恢复**，不再静默直接恢复。
    @Published var pendingRestore: PendingRestore?
    /// 用户点过「暂不恢复」后置 true，之后不再自动弹框（设置页手动入口仍可用）。
    @Published private(set) var restoreDeclined = false

    /// 待确认的恢复信息（云端有多少条会话/多少条消息）。
    struct PendingRestore: Identifiable {
        let id = UUID()
        let token: String
        let convCount: Int      // 会话数
        let msgCount: Int       // 消息总条数
    }

    /// 「暂不恢复」的持久化 flag（按 token 前缀存，换号后会重新问）。
    private var declineKey: String {
        let t = (Session.shared.token ?? "").prefix(8)
        return "cloudRestoreDeclined_\(t)"
    }

    /// 发消息后的去抖推送任务：新调用先 cancel 旧的，2 秒后执行。
    private var pushTask: Task<Void, Never>?

    // MARK: - 恢复（登录后先探测 → 用户确认）

    /// 登录后调用：**只探测**云端是否有数据，有则置 `pendingRestore` 让 UI 弹确认框。
    /// 不再直接合并落盘。若用户此前已「暂不恢复」，则不再弹。
    func probeForRestoreConfirm(token: String, email: String) async {
        // 已经明确拒绝过 → 不再打扰（设置页手动入口仍可调 restoreNow）
        if UserDefaults.standard.bool(forKey: declineKey) {
            await MainActor.run { self.restoreDeclined = true }
            NSLog("[CloudBackup] restore declined earlier, skip prompt")
            return
        }
        do {
            let json = try await APIClient.request("/v1/chat/backup", token: token)
            let data = (json["data"] as? [String: Any]) ?? json
            let cloud = Self.parseConvMap(data)
            guard !cloud.isEmpty else {
                NSLog("[CloudBackup] cloud backup empty, nothing to prompt")
                return
            }
            let msgCount = cloud.values.reduce(0) { $0 + $1.count }
            await MainActor.run {
                self.pendingRestore = PendingRestore(
                    token: token, convCount: cloud.count, msgCount: msgCount)
            }
            NSLog("[CloudBackup] cloud has \(cloud.count) convs / \(msgCount) msgs, ask user")
        } catch {
            NSLog("[CloudBackup] probe failed: \(error.localizedDescription)")
        }
    }

    /// 用户点「恢复」：真正合并云端到本地（合并语义不变：只补本地没有的，不删本地）。
    func confirmRestore() async {
        guard let p = pendingRestore else { return }
        await MainActor.run { self.pendingRestore = nil }
        do {
            let json = try await APIClient.request("/v1/chat/backup", token: p.token)
            let data = (json["data"] as? [String: Any]) ?? json
            let cloud = Self.parseConvMap(data)
            guard !cloud.isEmpty else { return }
            let added = LocalStore.merge(cloud: cloud)
            await MainActor.run {
                self.lastRestoreAt = Date()
                self.lastRestoreCount = added
                self.lastSyncText = "已从云端恢复 \(added) 条消息（\(cloud.count) 个会话）"
            }
            NSLog("[CloudBackup] user confirmed, restored \(added) msgs / \(cloud.count) convs")
        } catch {
            NSLog("[CloudBackup] confirm restore failed: \(error.localizedDescription)")
        }
    }

    /// 用户点「暂不恢复」：记 flag，之后不再自动问。（@Published 赋值需主线程）
    @MainActor
    func declineRestore() {
        UserDefaults.standard.set(true, forKey: declineKey)
        restoreDeclined = true
        pendingRestore = nil
        NSLog("[CloudBackup] user declined restore")
    }

    /// 设置页手动「从云端恢复」：清掉拒绝 flag、直接探测并恢复（不弹框，用户已主动点）。
    func restoreNow(token: String, email: String) async {
        UserDefaults.standard.set(false, forKey: declineKey)
        restoreDeclined = false
        do {
            let json = try await APIClient.request("/v1/chat/backup", token: token)
            let data = (json["data"] as? [String: Any]) ?? json
            let cloud = Self.parseConvMap(data)
            guard !cloud.isEmpty else {
                await MainActor.run { self.lastSyncText = "云端暂无聊天记录可恢复" }
                return
            }
            let added = LocalStore.merge(cloud: cloud)
            await MainActor.run {
                self.lastRestoreAt = Date()
                self.lastRestoreCount = added
                self.lastSyncText = "已从云端恢复 \(added) 条消息（\(cloud.count) 个会话）"
            }
            NSLog("[CloudBackup] manual restore: \(added) msgs / \(cloud.count) convs")
        } catch {
            await MainActor.run { self.lastSyncText = "从云端恢复失败：\(error.localizedDescription)" }
            NSLog("[CloudBackup] manual restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 旧接口（保留兼容，不再被 applyLogin 调用）

    /// 旧版静默恢复。保留供别的调用方兼容，但登录流程已改为先确认（probeForRestoreConfirm）。

    /// 登录后调用：凭登录 token GET 直拉自己账号的云端备份 → 解析 → 合并进本地。
    ///
    /// 不走 backupMeta 的 count（服务端 GET 根本不返回 count 字段，恒为 0），
    /// 也不走 recoverCode→recover 那条需要恢复码的路；登录即恢复，无需任何码。
    /// 任何一步失败都只记录日志，绝不影响登录流程。
    func restoreIfNeeded(token: String, email: String) async {
        do {
            let json = try await APIClient.request("/v1/chat/backup", token: token)
            let data = (json["data"] as? [String: Any]) ?? json
            let cloud = Self.parseConvMap(data)

            // 有无数据只认 convs 本身是否非空，绝不用 count/bytes（服务端无 count 字段）
            guard !cloud.isEmpty else {
                NSLog("[CloudBackup] cloud backup empty, skip restore")
                return
            }

            let added = LocalStore.merge(cloud: cloud)
            await MainActor.run {
                self.lastRestoreAt = Date()
                self.lastRestoreCount = added
                self.lastSyncText = "云端已同步 \(cloud.count) 条会话"
            }
            NSLog("[CloudBackup] restored \(added) msgs / \(cloud.count) convs from cloud GET")
        } catch {
            NSLog("[CloudBackup] restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - 推送（发消息后去抖调用）

    /// 同步函数、内部起 Task，方便 View 里发完消息直接调。token 为空直接返回。
    func pushIfNeeded(token: String?) {
        guard let token, !token.isEmpty else { return }
        pushTask?.cancel()
        pushTask = Task {
            // 去抖：2 秒内的连续调用只保留最后一次
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }

            let convs = LocalStore.exportAll()
            var payload: [String: [[String: String]]] = [:]
            for (pid, rows) in convs {
                payload[pid] = rows.map { row in
                    var d: [String: String] = [:]
                    for (k, v) in row { d[k] = (v as? String) ?? "\(v)" }
                    return d
                }
            }
            let total = payload.values.reduce(0) { $0 + $1.count }
            let convCount = payload.count

            do {
                try await APIClient.backupPush(token: token, convs: payload)
                await MainActor.run { self.lastSyncText = "云端已同步 \(convCount) 条会话" }
                NSLog("[CloudBackup] pushed \(total) msgs / \(convCount) convs")
            } catch {
                NSLog("[CloudBackup] push failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 解析云端 convs

    /// 把 GET /v1/chat/backup 的 `data` 字典解析成 `[pid: [msg]]`。
    /// 容错：data/backup 包裹、服务端 `_wrap_convs` 多包的一层 `convs`、
    /// 扁平 `{pid:[msg]}`；每条消息归一成 role/content/w/i/x/q。
    private static func parseConvMap(_ raw: Any?) -> [String: [[String: Any]]] {
        guard var root = raw as? [String: Any] else { return [:] }

        // 剥 data / backup 包装层（最多 3 层，防环）
        for _ in 0..<3 {
            if let d = root["data"] as? [String: Any] { root = d; continue }
            if let b = root["backup"] as? [String: Any] { root = b; continue }
            break
        }
        // 服务端 recover 接口 _wrap_convs 会多包一层 convs：取它
        if let c = root["convs"] as? [String: Any] { root = c }
        // 若剥完仍只剩一个名为 convs 的字典键，再剥一层
        if root.count == 1, let c = root["convs"] as? [String: Any] { root = c }

        var out: [String: [[String: Any]]] = [:]
        for (pid, value) in root {
            guard let rows = value as? [[String: Any]] else { continue }
            let normalized = rows.compactMap { normalizeMessage($0) }
            if !normalized.isEmpty { out[pid] = normalized }
        }
        return out
    }

    /// 每条消息转回本地字典：role/content/w/i/x/q。
    /// 同时兼容长字段名 who/img/skip/quote 与 skip 的 Bool/Int 写法。
    private static func normalizeMessage(_ row: [String: Any]) -> [String: Any]? {
        guard let role = row["role"] as? String,
              let content = row["content"] as? String else { return nil }
        var out: [String: Any] = ["role": role, "content": content]

        let w = (row["w"] as? String) ?? (row["who"] as? String) ?? ""
        let i = (row["i"] as? String) ?? (row["img"] as? String) ?? ""
        let q = (row["q"] as? String) ?? (row["quote"] as? String) ?? ""
        if !w.isEmpty { out["w"] = w }
        if !i.isEmpty { out["i"] = i }
        if !q.isEmpty { out["q"] = q }

        let xRaw: Any? = row["x"] ?? row["skip"]
        var x = ""
        if let s = xRaw as? String { x = s }
        else if let b = xRaw as? Bool, b { x = "1" }
        else if let n = xRaw as? Int, n != 0 { x = "1" }
        if !x.isEmpty { out["x"] = x }

        return out
    }
}
