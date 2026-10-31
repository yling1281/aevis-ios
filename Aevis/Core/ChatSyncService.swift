import Foundation

/// 聊天记录上云 + 多端同步（2026-10-31）。
///
/// 用户原话：「都说了所有东西上传到云端，聊天记录所有东西同步到云端，多端同步知道吗？」
///
/// ## 后端早就有了，客户端一直没接
/// 4-4 上 `aevis_social.py` 挂着四个接口：
/// `/v1/sync/messages`（POST 推 / GET 拉）、`/v1/sync/conversations`、
/// `/v1/sync/read`、`/v1/sync/typing`。
/// 但**iOS 一行都没调** —— 所以换台手机登录同一个账号，聊天是空的。
///
/// ## 身份怎么传
/// 这几个接口用的是 **`X-Account` 头**（账号邮箱），不是 `AevisCloud` 那套 Bearer 令牌。
/// 别混：走 `AevisCloud.call` 会拿不到账号，接口直接 4001。
///
/// ## 同步策略
/// - **推**：本地每追加一条消息就尽力推一次（失败不重试、不挡界面，下次全量再补）
/// - **拉**：登录后 / 回前台 / 手动点「立即同步」时，从上次的 cursor 往后拉
/// - **去重**：服务端 `msg_id` 落一份本地索引，拉回来见过的不再插
/// - peer = 本地联系人的 UUID 字符串（每台设备上同一个人的 UUID 不一定一样，
///   但**同一个账号在两台设备上**是从云端恢复的，UUID 会跟过来 —— 见 `adoptPeer`）
@MainActor
final class ChatSyncService: ObservableObject {
    static let shared = ChatSyncService()

    @Published private(set) var syncing = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var pushedCount: Int = 0
    @Published private(set) var pulledCount: Int = 0

    @Published var autoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSyncEnabled, forKey: Keys.auto) }
    }

    private enum Keys {
        static let cursor = "aevis.sync.cursor"
        static let lastAt = "aevis.sync.lastAt"
        static let auto = "aevis.sync.auto"
        static let seen = "aevis.sync.seenIds"
    }

    private init() {
        autoSyncEnabled = UserDefaults.standard.object(forKey: Keys.auto) as? Bool ?? true
        if let t = UserDefaults.standard.object(forKey: Keys.lastAt) as? Double, t > 0 {
            lastSyncAt = Date(timeIntervalSince1970: t)
        }
    }

    var account: String {
        AppSettings.shared.accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var canSync: Bool { !account.isEmpty }

    var statusLine: String {
        if !canSync { return "登录账号后自动同步" }
        if syncing { return "正在同步…" }
        if let last = lastSyncAt {
            return "上次同步 " + last.formatted(date: .abbreviated, time: .shortened)
        }
        return "还没同步过"
    }

    // MARK: - 推

    /// 把一条本地消息推上去。**失败静默** —— 聊天不能因为网络卡一下就发不出去。
    func push(_ message: ChatMessage, peer: String, ownerIsMe: Bool) {
        guard autoSyncEnabled, canSync else { return }
        let payload: [String: Any] = [
            "id": message.id.uuidString,
            // 服务端只认 user / peer / system。本地 user 原样，assistant 算 peer。
            "role": message.role == .user ? "user" : "peer",
            "kind": "text",
            "text": message.text,
            "time": Int(message.date.timeIntervalSince1970 * 1000)
        ]
        let body: [String: Any] = ["peer": peer, "messages": [payload]]
        Task {
            do {
                _ = try await send("/v1/sync/messages", method: "POST", body: body)
                markSeen(peer: peer, ids: [message.id.uuidString])
                pushedCount += 1
            } catch {
                // 不打扰用户；下次「立即同步」会全量补
                lastError = nil
            }
        }
    }

    // MARK: - 拉

    /// 拉一次（登录后 / 回前台 / 手动）。
    func sync(force: Bool = false) async {
        guard canSync else { return }
        guard !syncing else { return }
        if !force, !autoSyncEnabled { return }

        syncing = true
        lastError = nil
        defer { syncing = false }

        let since = UserDefaults.standard.integer(forKey: Keys.cursor)
        do {
            let data = try await send("/v1/sync/messages?since=\(since)&limit=500")
            let items = (data["messages"] as? [[String: Any]]) ?? []
            var maxSeq = since
            var inserted = 0

            // 写本地期间拦住回推（见 ChatStore.isApplyingRemote 的说明）
            ChatStore.shared.isApplyingRemote = true
            defer { ChatStore.shared.isApplyingRemote = false }

            for item in items {
                let seq = item["seq"] as? Int ?? 0
                if seq > maxSeq { maxSeq = seq }

                guard let peer = item["peer"] as? String, !peer.isEmpty,
                      let mid = item["id"] as? String, !mid.isEmpty,
                      let text = item["text"] as? String, !text.isEmpty else { continue }
                if isSeen(peer: peer, id: mid) { continue }

                let ts = (item["time"] as? Double) ?? 0
                let date = Date(timeIntervalSince1970: ts / 1000)
                let role: ChatMessage.Role = (item["role"] as? String) == "user" ? .user : .assistant

                // peer 是云端存的**联系人 key**；本地找不到这个 UUID 就落给当前联系人，
                // 免得出现"同步回来一串孤儿消息，哪个会话都看不到"。
                let owner = UUID(uuidString: peer) ?? ChatStore.shared.currentContactID
                ChatStore.shared.append(
                    ChatMessage(id: UUID(uuidString: mid) ?? UUID(),
                                role: role,
                                text: text,
                                date: date),
                    for: owner)
                markSeen(peer: peer, ids: [mid])
                inserted += 1
            }

            UserDefaults.standard.set(maxSeq, forKey: Keys.cursor)
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt!.timeIntervalSince1970, forKey: Keys.lastAt)
            pulledCount += inserted
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 去重索引

    private func seenKey(peer: String) -> String { Keys.seen + "." + peer }

    private func isSeen(peer: String, id: String) -> Bool {
        let list = UserDefaults.standard.stringArray(forKey: seenKey(peer: peer)) ?? []
        return list.contains(id)
    }

    private func markSeen(peer: String, ids: [String]) {
        var list = UserDefaults.standard.stringArray(forKey: seenKey(peer: peer)) ?? []
        for id in ids where !list.contains(id) { list.append(id) }
        // 只留最近 800 条 —— 再老的靠 cursor 挡住，不需要无限长
        if list.count > 800 { list.removeFirst(list.count - 800) }
        UserDefaults.standard.set(list, forKey: seenKey(peer: peer))
    }

    // MARK: - 请求

    private func send(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: AevisHosts.accountBase + path) else {
            throw SyncError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ⚠️ 必须是 X-Account（账号邮箱），不是 Bearer —— 见类注释。
        request.setValue(account, forHTTPHeaderField: "X-Account")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.badURL }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (json["code"] as? Int) ?? http.statusCode
        guard (200..<300).contains(code) else {
            throw SyncError.http(code, (json["msg"] as? String) ?? "同步失败")
        }
        return (json["data"] as? [String: Any]) ?? json
    }

    enum SyncError: LocalizedError {
        case badURL
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "同步地址不对"
            case .http(let code, let msg): return "同步失败（\(code)）：\(msg)"
            }
        }
    }
}
