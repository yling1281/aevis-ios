import Foundation
import SwiftUI

/// 一条站内信。
///
/// 2026-11-01 从 `InboxView` 里搬出来：**「我」页要显示未读数**，
/// 所以数据不能再锁在某个页面的 `@State` 里 —— 得有一个全局的地方存。
struct InboxItem: Identifiable, Hashable {
    let id: Int
    let kind: String          // notice / welfare
    let title: String
    let body: String
    let points: Int
    var claimed: Bool
    var read: Bool
    let createdAt: String

    var isWelfare: Bool { kind == "welfare" && points > 0 }

    init(dict: [String: Any]) {
        id = dict["id"] as? Int ?? 0
        kind = dict["kind"] as? String ?? "notice"
        title = dict["title"] as? String ?? ""
        body = dict["body"] as? String ?? ""
        points = dict["points"] as? Int ?? 0
        claimed = (dict["claimed"] as? Bool) ?? false
        read = (dict["read"] as? Bool) ?? false
        createdAt = dict["created_at"] as? String ?? ""
    }
}

/// 站内信（通知 + 福利积分）。
///
/// 后端：`/v1/inbox/list|read|unread|claim`，用户身份走 `X-Account`
///（和社交 / 云同步同一套）。
///
/// 2026-11-01 用户说「站内信你没弄好」。当时的样子：
/// 列表能看、福利能领，但**从来不告诉服务器"我看过了"** ——
/// 红点永远消不掉；「我」页那一行也永远只有一句死文案，
/// 有未读也看不出来。现在这三件事都由这个 store 负责：
///   ① `refresh()`           拉列表 + 未读数
///   ② `markAllRead()`       进列表就把这批标已读（红点当场消失）
///   ③ `badge`               「我」页 / tab 上的数字
@MainActor
final class InboxStore: ObservableObject {
    static let shared = InboxStore()

    @Published private(set) var rows: [InboxItem] = []
    @Published private(set) var unread: Int = 0
    @Published private(set) var loading = false
    @Published private(set) var lastError: String?

    private var account: String {
        AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var base: String { AevisHosts.accountBase }

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) -> URLRequest? {
        guard !account.isEmpty, let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(account, forHTTPHeaderField: "X-Account")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// 只拉未读数 —— 「我」页每次出现都调，很便宜（服务端只 COUNT）。
    func refreshBadge() async {
        guard !account.isEmpty else { unread = 0; return }
        guard let req = request("/v1/inbox/unread"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any] else { return }
        unread = d["unread"] as? Int ?? 0
    }

    /// 拉完整列表。
    func refresh() async {
        guard !account.isEmpty else {
            rows = []; unread = 0; loading = false; return
        }
        loading = rows.isEmpty
        defer { loading = false }
        guard let req = request("/v1/inbox/list"),
              let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let items = d["rows"] as? [[String: Any]] else { return }
        rows = items.map(InboxItem.init(dict:))
        unread = d["unread"] as? Int ?? 0
        lastError = nil
    }

    /// 把当前所有未读一次性标已读。进去看了就算看过 —— 不用一条条点。
    func markAllRead() async {
        let ids = rows.filter { !$0.read }.map { $0.id }
        guard !ids.isEmpty, let req = request("/v1/inbox/read", method: "POST",
                                             body: ["ids": ids]) else { return }
        _ = try? await URLSession.shared.data(for: req)
        for i in rows.indices { rows[i].read = true }
        unread = 0
    }

    /// 领福利。返回 (是否成功, 提示语, 新的余额)。
    func claim(_ id: Int) async -> (Bool, String, Int?) {
        guard let req = request("/v1/inbox/claim", method: "POST", body: ["id": id]) else {
            return (false, "先登录账号", nil)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "网络异常，稍后再试", nil)
        }
        let code = obj["code"] as? Int ?? -1
        let msg = obj["msg"] as? String ?? ""
        if code != 0 { return (false, msg.isEmpty ? "领取失败" : msg, nil) }
        let d = obj["data"] as? [String: Any]
        let balance = d?["balance"] as? Int
        if let idx = rows.firstIndex(where: { $0.id == id }) {
            rows[idx].claimed = true
            rows[idx].read = true
        }
        unread = max(0, unread - 0)
        await refresh()
        return (true, msg.isEmpty ? "已领取" : msg, balance)
    }
}
