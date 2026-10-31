import Foundation

/// 积分（2026-10-31 新增）
///
/// 用户要求：「目前只有会员充值，需要补做积分充值功能，本次一并实现，
/// 兑换比例为 1 元 = 200 积分」。
///
/// ⚠️ **比例只在服务端算**（`points_for_cents`），这里一律用后端返回的 `points`，
///    不在客户端再乘一次 —— 两处各算一次迟早对不上，而且对不上时用户只会骂"少给了"。
///
/// ⚠️ 所有请求都走 `AevisCloud.call`，令牌就是账号登录那一个
///    （2026-10-31 起账号站和业务站是同一个 4-4 后端）。
@MainActor
final class PointsService: ObservableObject {
    static let shared = PointsService()

    // ---- 余额 ----
    @Published private(set) var points: Int = 0
    @Published private(set) var yuan: String = "0.00"
    @Published private(set) var rate: String = "1 元 = 200 积分"

    // ---- 商店 ----
    @Published private(set) var items: [ShopItem] = []
    @Published private(set) var redeemOrders: [RedeemOrder] = []

    // ---- 充值 ----
    @Published private(set) var packages: [Package] = []
    @Published private(set) var payEnabled: Bool = false
    @Published private(set) var recharges: [Recharge] = []

    @Published private(set) var loading: Bool = false
    @Published private(set) var refreshing: Bool = false
    @Published var error: String?

    /// 已下单、等着用户在浏览器里付完的那一单。界面顶部拿它显示一条提示。
    @Published var pending: PendingRecharge?

    private init() {}

    // MARK: - 模型

    struct ShopItem: Identifiable, Equatable {
        let id: Int
        let code: String
        let name: String
        let note: String
        let cost: Int
        let soldOut: Bool
    }

    struct RedeemOrder: Identifiable, Equatable {
        let id: Int
        let itemName: String
        let cost: Int
        let note: String
        let createdAt: String
    }

    struct Package: Identifiable, Equatable {
        var id: String { code }
        let code: String
        let name: String
        let amountCents: Int
        let amountYuan: String
        let points: Int
    }

    struct Recharge: Identifiable, Equatable {
        var id: String { orderNo }
        let orderNo: String
        let state: String
        let amountYuan: String
        let points: Int
        let createdAt: String
        let paidAt: String
    }

    struct PendingRecharge: Identifiable, Equatable {
        var id: String { orderNo }
        let orderNo: String
        let amountYuan: String
        let points: Int
        let payURL: String
    }

    // MARK: - 拉取

    /// 一次把「余额 + 商品 + 充值包 + 记录」拉齐。
    ///
    /// 用 `async let` 并行：四个请求串行在弱网下会明显卡（每个 1~2 秒就够用户以为死了）。
    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            async let home = AevisCloud.call("/v1/points")
            async let pkg = AevisCloud.call("/v1/points/recharge/packages")
            async let ords = AevisCloud.call("/v1/points/orders?limit=30")
            async let recs = AevisCloud.call("/v1/points/recharge/records?limit=30")

            let (h, p, o, r) = try await (home, pkg, ords, recs)

            points = (h["points"] as? Int) ?? 0
            yuan = (h["yuan"] as? String) ?? "0.00"
            rate = (h["rate"] as? String) ?? "1 元 = 200 积分"
            items = ((h["items"] as? [[String: Any]]) ?? []).map { d in
                ShopItem(
                    id: (d["id"] as? Int) ?? 0,
                    code: (d["code"] as? String) ?? "",
                    name: (d["name"] as? String) ?? "",
                    note: (d["note"] as? String) ?? "",
                    cost: (d["cost"] as? Int) ?? 0,
                    soldOut: (d["soldOut"] as? Bool) ?? false
                )
            }
            packages = ((p["items"] as? [[String: Any]]) ?? []).map { d in
                Package(
                    code: (d["code"] as? String) ?? "",
                    name: (d["name"] as? String) ?? "",
                    amountCents: (d["amountCents"] as? Int) ?? 0,
                    amountYuan: (d["amountYuan"] as? String) ?? "0.00",
                    points: (d["points"] as? Int) ?? 0
                )
            }
            payEnabled = (p["payEnabled"] as? Bool) ?? false
            redeemOrders = ((o["items"] as? [[String: Any]]) ?? []).map { d in
                RedeemOrder(
                    id: (d["id"] as? Int) ?? 0,
                    itemName: (d["item_name"] as? String) ?? "",
                    cost: (d["cost"] as? Int) ?? 0,
                    note: (d["note"] as? String) ?? "",
                    createdAt: (d["created_at"] as? String) ?? ""
                )
            }
            recharges = ((r["items"] as? [[String: Any]]) ?? []).map { d in
                Recharge(
                    orderNo: (d["orderNo"] as? String) ?? "",
                    state: (d["state"] as? String) ?? "",
                    amountYuan: (d["amountYuan"] as? String) ?? "0.00",
                    points: (d["points"] as? Int) ?? 0,
                    createdAt: (d["createdAt"] as? String) ?? "",
                    paidAt: (d["paidAt"] as? String) ?? ""
                )
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - 充值

    /// 建单并返回收银台地址。**不在这里跳转** —— 跳转由界面决定（便于加"复制链接"兜底）。
    func createRecharge(package code: String, payType: String = "wxpay") async throws -> PendingRecharge {
        let d = try await AevisCloud.call("/v1/points/recharge", method: "POST",
                                          body: ["package": code, "payType": payType])
        let p = PendingRecharge(
            orderNo: (d["orderNo"] as? String) ?? "",
            amountYuan: (d["amountYuan"] as? String) ?? "0.00",
            points: (d["points"] as? Int) ?? 0,
            payURL: (d["payUrl"] as? String) ?? ""
        )
        pending = p
        return p
    }

    /// 核一次这一单到底到账没有。
    ///
    /// 返回 `nil` 表示还在 pending（没到账）；返回数字表示刚入账的积分。
    /// 抛错表示查询失败（网络/登录态问题），界面要如实说，别当成"没付"。
    func checkPending() async throws -> Int? {
        guard let p = pending else { return nil }
        let d = try await AevisCloud.call("/v1/points/recharge/\(p.orderNo)")
        let state = (d["state"] as? String) ?? ""
        if state == "paid" {
            let got = (d["points"] as? Int) ?? p.points
            pending = nil
            await refresh()
            return got
        }
        if state == "refunded" {
            pending = nil
            await refresh()
            return 0
        }
        return nil
    }

    func clearPending() { pending = nil }

    // MARK: - 兑换

    func redeem(_ item: ShopItem) async throws -> String {
        let d = try await AevisCloud.call("/v1/points/redeem", method: "POST",
                                          body: ["itemId": item.id])
        await refresh()
        let status = (d["status"] as? String) ?? ""
        let note = (d["note"] as? String) ?? ""
        if !note.isEmpty { return note }
        switch status {
        case "done": return "已到账"
        case "refunded": return "发货失败，积分已退回"
        default: return "已提交，客服会尽快处理"
        }
    }
}
