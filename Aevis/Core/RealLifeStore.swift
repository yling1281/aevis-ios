import Foundation
import Combine

// 「真实生活」的数据层 —— 给「发现页 → 真实生活」那一页用。
//
// 老板要的（原话）：发现页加一个「真实生活」，里面有**模拟的淘宝 / 拼多多**，
// 后来又补了一句「加一个可以开亲密服，可以代付，然后点外卖」——
// 所以这一页里有**两个世界**：
//   ① 购物（淘宝 / 拼多多那种） ② 外卖（美团 / 饿了么那种）
// 每个世界都要「完整版」：有店、有货、有订单、有**按时间自动推进的物流**、
// 有**假客服聊天**。亲密付 / 代付的**钱**由做钱包的人负责，这里只记「谁付的」。
//
// 🎨 视觉口径（下一轮做 UI 的人请注意）：
//   那一页是**苹果玻璃质感** —— 背景**纯白或纯黑、不要任何渐变**，
//   分层靠材质 / 细边框 / 阴影，别加彩色渐变、别加花纹。
//   店的 `logo` 和商品的 `icon` 都是 **emoji 字符串**，直接当图片显示即可。
//
// 本轮只做**数据层**（纯逻辑 + 内置数据），一行 UI 都不写。
//
// ⭐ 2026-10：当初留给"下一轮"的两件事都做完了 ——
//   ① 下单的扣钱已接上钱包：结算页 `CheckoutSheet.submit()` 在调 `placeOrder` **之前**
//      按选中的付款方式调 `WalletStore`（`spendAsMe` / `closePaySpend` / `proxyPay`），
//      返 0（没付成）就当场拦下、**绝不落单**。
//   ② 本 Store 已登记进 `BackupService.stores()`（`backupName = "reallife"`），
//      换手机搬家时订单和假客服会一起搬走。

// MARK: - 场景

/// 「真实生活」里的两个世界。
enum RealLifeKind: String, Codable, CaseIterable {
    case shopping   // 网购（淘宝 / 拼多多那种）
    case food       // 外卖（美团 / 饿了么那种）

    var title: String {
        switch self {
        case .shopping: return "购物"
        case .food: return "外卖"
        }
    }
}

// MARK: - 谁付的钱

/// 这笔订单是谁出的钱。
///
/// ⭐ 2026-10：已经**真的接上钱包了** —— 扣款由结算页
///    `CheckoutSheet.submit()` 在调 `placeOrder` **之前**完成
///    （`spendAsMe` / `closePaySpend` / `proxyPay`），付不成就当场拦下、绝不落单。
///    这里只如实记下"谁付的"这一件事。
///    亲密付 / 代付还分**方向**，另见 `Order.payDirection`。
enum PaidBy: String, Codable, CaseIterable {
    case me        // 我自己付
    case closePay  // 亲密付
    case proxy     // 代付（ta替我付）
    case self_ = "self"   // ta自己的钱

    var title: String {
        switch self {
        case .me: return "我付"
        case .closePay: return "亲密付"
        case .proxy: return "代付"
        case .self_: return "\(Pronoun.current)自己付"
        }
    }
}

// MARK: - 订单轨迹

/// 订单走到哪一步了。购物和外卖**走两条不同的线**，但都从「已下单」开始。
///
/// 🔴 **阶段不许存盘** —— 它是随时钟自己往前走的。
///    存进磁盘的是 `Order.createdAt`，「现在到哪一步」由
///    `RealLifeStore.resolvedStage(...)` 现算。
///    要是把"当前阶段"也存下来，关掉 App 再打开，进度就永远卡在那一步不动了
///    —— 这正是老板最会一眼看穿的"假"。
enum OrderStage: String, Codable, CaseIterable, Equatable {
    // —— 购物轨迹 ——
    case placed          // 已下单
    case shipped         // 商家已发货
    case inTransit       // 运输中
    case outForDelivery  // 派送中
    case received        // 已签收
    // —— 外卖轨迹 ——
    case accepted        // 商家已接单
    case pickedUp        // 骑手已取餐
    case delivering      // 配送中
    case delivered       // 已送达

    var title: String {
        switch self {
        case .placed: return "已下单"
        case .shipped: return "商家已发货"
        case .inTransit: return "运输中"
        case .outForDelivery: return "派送中"
        case .received: return "已签收"
        case .accepted: return "商家已接单"
        case .pickedUp: return "骑手已取餐"
        case .delivering: return "配送中"
        case .delivered: return "已送达"
        }
    }

    /// 这个场景下，从下单到送达依次经过哪几个阶段。
    static func track(for kind: RealLifeKind) -> [OrderStage] {
        switch kind {
        case .shopping: return [.placed, .shipped, .inTransit, .outForDelivery, .received]
        case .food: return [.placed, .accepted, .pickedUp, .delivering, .delivered]
        }
    }

    /// 每个阶段「从 `createdAt` 起要过多少秒」才算到 —— 与 `track(for:)` 一一对应。
    ///
    /// 两条线的时间尺度**完全不同**：购物按小时算，外卖按分钟算。
    static func offsets(for kind: RealLifeKind) -> [TimeInterval] {
        switch kind {
        case .shopping:
            return [0, 4 * 3600, 18 * 3600, 40 * 3600, 52 * 3600]   // +0h / +4h / +18h / +40h / +52h
        case .food:
            return [0, 60, 300, 720, 1500]                           // +0 / +1min / +5min / +12min / +25min
        }
    }
}

// MARK: - 店 / 货 / 单 / 客服

/// 一家店。购物店和外卖店**共用**这个结构，靠 `kind` 区分。
struct Shop: Codable, Identifiable, Equatable {
    var id: String
    var kind: RealLifeKind
    var name: String
    /// 店招 —— 用 emoji 当 logo（下一轮 UI 直接当图片显示）。
    var logo: String
    var rating: Double
    var monthlySales: Int
    /// 配送费（购物多是包邮 = 0）。
    var deliveryFee: Double
    /// 起送价。
    var minOrder: Double
    /// 预计送达（分钟）。购物就是"预计 X 小时"，外卖就是"预计 X 分钟"。
    var etaMinutes: Int
    var tags: [String]
}

/// 一件商品 / 一道菜。同样是**共用**结构。
struct Goods: Codable, Identifiable, Equatable {
    var id: String
    var shopID: String
    var name: String
    var price: Double
    var sales: Int
    var desc: String
    /// 商品图 —— 用 emoji（下一轮 UI 直接显示）。
    var icon: String
}

/// 订单里的一行。**故意用结构体，不用元组** —— 元组不是 `Codable`，存不了盘。
struct OrderItem: Codable, Equatable {
    var name: String
    var price: Double
    var count: Int

    /// 这一行的小计（夹成两位小数，免得 0.1 + 0.2 那种浮点尾巴）。
    var subtotal: Double {
        (price * Double(count) * 100).rounded() / 100
    }
}

/// 一笔订单。
///
/// ⚠️ **`stage` 是算出来的，不是存的** —— 见 `OrderStage` 上方那段说明。
///    `Codable` 只编码下面的存储属性；`stage` 每次读都按**当前时间**现算，
///    所以关掉 App 再打开，进度会自己接着往前跑。
struct Order: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var shopID: String
    var kind: RealLifeKind
    var items: [OrderItem] = []
    var total: Double = 0
    var createdAt: Date = Date()
    var paidBy: PaidBy = .me
    /// 亲密付 / 代付的**方向**（`"mine"` / `"ta"`）；`.me` / `.self_` 时留空。
    ///
    /// 🔴 **必须是 Optional + 默认值 `nil`** —— 老订单的 JSON 里根本没有这个键，
    ///    靠编译器合成的 `decodeIfPresent` 走 nil，**不许抛错**（同 `WalletStore.Entry`
    ///    那几行的既定做法）。
    var payDirection: String? = nil
    /// 下单那一刻的**配送费快照**。
    ///
    /// 🔴 为什么要把配送费冻进订单：结算页扣的是 `商品小计 + 配送费`，而 `total` 只装
    ///    商品小计。不一起存下来的话，订单页只能**回头再查一次店铺**才能把两个数凑齐 ——
    ///    一旦查不到店铺，合计就凭空少一笔配送费，跟钱包那边扣的对不上。
    /// 🔴 **必须是 Optional + 默认值 `nil`** —— 老订单没有这个键，走 nil 不许抛错
    ///    （同 `payDirection` / `WalletStore.Entry` 的做法）；老档由界面退回按店铺现查。
    var deliveryFee: Double? = nil
    var addressHint: String = ""

    /// **实付** = 商品小计（`total`）+ 配送费快照。
    ///
    /// ⚠️ `total` 只是**商品小计**、不是实付。要显示 / 对账的"实付"一律走这里，
    ///    别在外面手拼 `total + 配送费` —— 那正是"订单合计和钱包扣款对不上"的根源。
    var amountPaid: Double { total + (deliveryFee ?? 0) }

    /// 现在走到哪一步了（按 `createdAt` 到"现在"的时间差现算）。
    var stage: OrderStage {
        RealLifeStore.resolvedStage(kind: kind, createdAt: createdAt)
    }

    /// 到终点了没有（购物=已签收，外卖=已送达）。
    var isFinished: Bool {
        stage == .received || stage == .delivered
    }
}

/// 假客服对话里的一句话。
struct ChatLine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// "me" = 我说的；"shop" = 店家 / 客服 / 骑手说的。
    var from: String
    var text: String
    var at: Date = Date()

    var isMe: Bool { from == "me" }
}

/// 一笔订单对应的一段假客服对话。
struct ShopChat: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var orderID: UUID
    var lines: [ChatLine] = []
}

// MARK: - Store

/// 「真实生活」的总 Store（购物 + 外卖）。
///
/// 照 `TodoStore` 的路子写：`ObservableObject` + `static let shared` +
/// `@Published` + 一个 `loading` 标志位（读档 / 搬家期间只读不写）+
/// **按联系人分开存**（JSON 落 `Application Support/aevis-reallife-by-contact.json`）。
/// **钱不归这里管** —— 扣款由结算页在 `placeOrder` 之前做完。
///
/// ⚠️ 换人由 `PersonaStore.broadcastSwitch` 统一通知 ——「给 A 下的单、跟 A 的假客服」
///    换到 B 就不该还看得见。老版本（单人）那两枚扁平键会在**第一次认人**时
///    搬到那个人的名下，一条不丢（见 `setOwner`）。
final class RealLifeStore: ObservableObject {

    static let shared = RealLifeStore()

    // MARK: 内置数据（只读，不进备份）

    /// 内置的全部店铺（购物 + 外卖）。
    let allShops: [Shop]
    /// 内置的全部商品 / 菜品。
    let allGoods: [Goods]

    // MARK: 我的数据

    /// 当前联系人的订单，**新的在最前**。只由 `placeOrder` 改。
    @Published private(set) var allOrders: [Order] = []

    /// 当前联系人的每笔订单对应的假客服对话。
    @Published private(set) var allChats: [ShopChat] = []

    /// 每个人的订单 + 客服对话，**按联系人分开存**（老版本是一份，见 `setOwner` 的迁移）。
    private var byOwner: [UUID: OwnerData] = [:]
    /// 现在这份属于谁。
    private var owner: UUID?

    /// 读档 / 搬家导入期间**只读不写**（同 `TodoStore.loading`）。
    private var loading = false

    /// 新格式存档读到没有 / 老存档认过没有 —— 老的那两枚扁平键只认一次。
    private var loadedArchive = false
    private var adoptedLegacy = false

    private let fileURL: URL

    /// 某个联系人的全部「真实生活」数据。存文件 / 进备份都走它。
    struct OwnerData: Codable {
        var orders: [Order] = []
        var chats: [ShopChat] = []
    }

    /// 老版本（单人）用的两枚扁平键，**只用来做一次性迁移**。
    private enum LegacyKey {
        static let orders = "aevis.reallife.orders"
        static let chats = "aevis.reallife.chats"
    }

    /// 订单最多留多少条。再多也没人翻。
    private static let maxOrders = 100

    private init() {
        allShops = Self.buildShops()
        allGoods = Self.buildGoods()
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("aevis-reallife-by-contact.json")
        load()
    }

    // MARK: - 查询（对外接口）

    /// 某个场景下的所有店。
    func shops(kind: RealLifeKind) -> [Shop] {
        allShops.filter { $0.kind == kind }
    }

    /// 按 id 找一家店。
    func shop(id: String) -> Shop? {
        allShops.first { $0.id == id }
    }

    /// 一家店里的全部商品 / 菜品。
    func goods(shopID: String) -> [Goods] {
        allGoods.filter { $0.shopID == shopID }
    }

    /// 全部订单（新的在前）。
    func orders() -> [Order] {
        allOrders
    }

    /// 某笔订单的假客服对话。
    func chat(orderID: UUID) -> ShopChat? {
        allChats.first { $0.orderID == orderID }
    }

    // MARK: - 物流：按时间现算（纯函数）

    /// 现在走到哪一步了 —— **纯函数**，只看 `createdAt` 到 `now` 的时间差。
    ///
    /// 给 `Order.stage` 和 UI 共用。绝不去读"存下来的阶段"（那东西根本不存在）。
    static func resolvedStage(kind: RealLifeKind, createdAt: Date, now: Date = Date()) -> OrderStage {
        let track = OrderStage.track(for: kind)
        let offsets = OrderStage.offsets(for: kind)
        let elapsed = max(0, now.timeIntervalSince(createdAt))
        var current = track.first ?? .placed
        for (index, stage) in track.enumerated() where index < offsets.count {
            if elapsed >= offsets[index] {
                current = stage
            } else {
                break
            }
        }
        return current
    }

    /// 实例版 —— 照规格给的签名，方便 UI 直接 `store.stage(of: order)`。
    func stage(of order: Order, now: Date = Date()) -> OrderStage {
        Self.resolvedStage(kind: order.kind, createdAt: order.createdAt, now: now)
    }

    /// 这个场景、这一步，假客服会说的一句**固定话术**。
    ///
    /// 下一轮 UI 自己按订单当前阶段取用即可（也可以直接看 `scriptedLine(for:)`）。
    static func shopLine(kind: RealLifeKind, stage: OrderStage) -> String {
        switch (kind, stage) {
        case (.shopping, .placed): return "亲，已经给您打包好啦～物流单号稍后同步给您哦～"
        case (.shopping, .shipped): return "亲，包裹已经从仓库发出啦，路上注意查收哦～"
        case (.shopping, .inTransit): return "亲，快递已经在路上咯，注意查收哦～"
        case (.shopping, .outForDelivery): return "亲，今天就给您送到，记得保持电话畅通哦～"
        case (.shopping, .received): return "亲，收到货麻烦给小店一个五星好评呀～么么哒～"
        case (.food, .placed): return "亲，您的订单已收到，商家马上为您确认～"
        case (.food, .accepted): return "商家已接单，正在火速出餐中，请耐心等待～"
        case (.food, .pickedUp): return "骑手已取餐，预计 12 分钟送到～"
        case (.food, .delivering): return "骑手正在飞奔途中，马上就到啦～"
        case (.food, .delivered): return "餐已送达，趁热吃哦～记得给个五星呀～"
        default: return "亲，有需要随时喊我～"
        }
    }

    /// 某笔订单**此刻**该收到的那句话术。
    func scriptedLine(for order: Order, now: Date = Date()) -> String {
        Self.shopLine(kind: order.kind, stage: stage(of: order, now: now))
    }

    // MARK: - 下单

    /// 这笔订单现在**下得了吗** —— 纯只读预检。
    ///
    /// 判据与 `placeOrder` 开头那两个 `guard` **逐字一致**：店得存在 +
    /// 清洗掉数量为 0 的行之后还得有东西。
    /// 结算页靠它**在扣钱之前**把关 —— 否则会出现"钱扣了、订单没落"的死角。
    func canPlaceOrder(shopID: String, items: [OrderItem]) -> Bool {
        guard shop(id: shopID) != nil else { return false }
        return !items.filter { $0.count > 0 }.isEmpty
    }

    /// 下一单。
    ///
    /// ⚠️ **这里只管"记录订单 + 开一段客服对话"，钱一分没动。**
    ///    扣款由结算页在调它**之前**做（见 `PaidBy` 上方那段）——
    ///    所以它是**纯数据层**，别在这里再扣一次，否则同一笔单会被扣两回。
    ///    返回刚建的订单；店不存在或没有商品时返回 `nil`。
    @discardableResult
    func placeOrder(shopID: String, items: [OrderItem], paidBy: PaidBy,
                    payDirection: String? = nil, addressHint: String) -> Order? {
        guard let shop = shop(id: shopID) else { return nil }
        let cleaned = items.filter { $0.count > 0 }
        guard !cleaned.isEmpty else { return nil }

        let total = (cleaned.reduce(0) { $0 + $1.subtotal } * 100).rounded() / 100
        let order = Order(
            shopID: shop.id,
            kind: shop.kind,
            items: cleaned,
            total: total,
            createdAt: Date(),
            paidBy: paidBy,
            payDirection: payDirection,
            deliveryFee: shop.deliveryFee,
            addressHint: addressHint.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var list = allOrders
        list.insert(order, at: 0)
        if list.count > Self.maxOrders {
            list.removeLast(list.count - Self.maxOrders)
        }
        allOrders = list

        // 顺手开一段假客服对话，先由店家说第一句。
        let opening = ChatLine(
            from: "shop",
            text: Self.shopLine(kind: shop.kind, stage: .placed),
            at: Date()
        )
        allChats.append(ShopChat(orderID: order.id, lines: [opening]))

        save()
        return order
    }

    /// 往某笔订单的假客服对话里追加一句。
    ///
    /// `from` 用 "me"（我发的）或 "shop"（店家 / 骑手发的）。
    /// 没有这段对话就现开一段 —— 下一轮聊天 UI 第一次发消息时用得上。
    func appendChatLine(orderID: UUID, from: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let line = ChatLine(from: from, text: trimmed, at: Date())
        if let index = allChats.firstIndex(where: { $0.orderID == orderID }) {
            allChats[index].lines.append(line)
        } else {
            allChats.append(ShopChat(orderID: orderID, lines: [line]))
        }
        save()
    }

    // MARK: - 切人

    /// 切到某个联系人。`PersonaStore` 切人时来调它。
    func setOwner(_ id: UUID?) {
        stash()
        owner = id

        guard let id else {
            allOrders = []
            allChats = []
            return
        }

        // 老版本只有一份、没分人 —— 认给**第一个进来的人**。
        // 只在「没有新格式存档」并且「还没认过」的时候做一次。
        if !loadedArchive, !adoptedLegacy {
            adoptedLegacy = true
            adoptLegacy(into: id)
        }

        let data = byOwner[id] ?? OwnerData()
        allOrders = data.orders
        allChats = data.chats
    }

    /// 把某个联系人的订单 / 客服对话整个删掉（删联系人时用）。
    func forget(_ id: UUID) {
        byOwner[id] = nil
        if owner == id {
            allOrders = []
            allChats = []
        }
        save()
    }

    // MARK: - 存档

    /// 存档 / 备份共用的结构。
    ///
    /// - `byOwner`：新结构，按联系人。
    /// - `orders` / `chats`：**只在读老备份时非空**（老版本只有单人那一份）。
    ///   ⚠️ 一律 Optional + 默认 nil，且写盘时是 nil ⇒ 序列化会用 `encodeIfPresent`
    ///      把它们**省略**掉，新备份里不会多出这两段。
    private struct Archive: Codable {
        /// 新结构，按联系人。🔴 **必须可选项** —— Swift 合成的 `Decodable` 不吃
        /// 属性默认值，非可选缺键会直接抛 `keyNotFound`（老单人备份整条解不出）。
        /// 老备份没有这个键 ⇒ nil，`orders`/`chats` 才有值。
        var byOwner: [String: OwnerData]? = nil
        var orders: [Order]? = nil
        var chats: [ShopChat]? = nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let archived = try? JSONDecoder().decode(Archive.self, from: data) else {
            return
        }
        // ⚠️ 读档期间禁写，理由同 `TodoStore.load()`：紧接着的 `setOwner` 会先
        //    `stash()`，用旧机器的那份盖掉刚读进来的。
        loading = true
        defer { loading = false }
        byOwner = (archived.byOwner ?? [:]).reduce(into: [:]) { result, pair in
            guard let id = UUID(uuidString: pair.key) else { return }
            result[id] = pair.value
        }
        loadedArchive = true
    }

    /// 老版本那两枚扁平键 → 这个人名下。**只调一次**（调用点已保证）。
    private func adoptLegacy(into id: UUID) {
        let defaults = UserDefaults.standard
        var data = byOwner[id] ?? OwnerData()
        if let raw = defaults.data(forKey: LegacyKey.orders),
           let list = try? JSONDecoder().decode([Order].self, from: raw),
           !list.isEmpty {
            data.orders = list
        }
        if let raw = defaults.data(forKey: LegacyKey.chats),
           let list = try? JSONDecoder().decode([ShopChat].self, from: raw),
           !list.isEmpty {
            data.chats = list
        }
        byOwner[id] = data
        // 认过就落盘。**老键不清** —— 删了就真没了，留着它零成本。
        writeArchive()
    }

    /// 把当前这份写回字典。任何落盘之前都要先做一次。
    private func stash() {
        guard !loading else { return }
        guard let owner else { return }
        byOwner[owner] = OwnerData(orders: allOrders, chats: allChats)
    }

    private func save() {
        guard !loading else { return }
        stash()
        writeArchive()
    }

    /// 把 `byOwner` 原样落盘，**不经过 `stash()`**。导入 / 迁移时用。
    private func writeArchive() {
        // 空字典不落盘 —— 否则第一次启动还没认人就会写一份空存档，
        // 下次就再也认不到老的那份了。
        guard !byOwner.isEmpty else { return }
        let flat = byOwner.reduce(into: [String: OwnerData]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        guard let encoded = try? JSONEncoder().encode(Archive(byOwner: flat)) else { return }
        try? encoded.write(to: fileURL, options: .atomic)
    }

    // MARK: - 内置店 / 货

    /// 内置的店铺。**店名都是编的，不许用真实商家的商标**。
    private static func buildShops() -> [Shop] {
        [
            // —— 购物：数码 ——
            Shop(id: "shop-digital", kind: .shopping, name: "果壳数码专营店", logo: "📱",
                 rating: 4.8, monthlySales: 12483, deliveryFee: 0, minOrder: 99, etaMinutes: 2880,
                 tags: ["旗舰店", "顺丰包邮", "7 天无理由"]),
            // —— 购物：服饰 ——
            Shop(id: "shop-fashion", kind: .shopping, name: "南栀女装工作室", logo: "👗",
                 rating: 4.7, monthlySales: 8621, deliveryFee: 8, minOrder: 69, etaMinutes: 4320,
                 tags: ["当季新款", "满 199 减 30", "支持退换"]),
            // —— 购物：零食 ——
            Shop(id: "shop-snack", kind: .shopping, name: "解忧零食铺子", logo: "🍬",
                 rating: 4.9, monthlySales: 30517, deliveryFee: 0, minOrder: 39, etaMinutes: 2880,
                 tags: ["整箱包邮", "临期特惠", "吃货必囤"]),
            // —— 购物：家居 ——
            Shop(id: "shop-home", kind: .shopping, name: "拾光家居生活馆", logo: "🛋️",
                 rating: 4.7, monthlySales: 6540, deliveryFee: 6, minOrder: 59, etaMinutes: 5760,
                 tags: ["家居好物", "破损包赔", "顺丰发货"]),
            // —— 购物：百货 ——
            Shop(id: "shop-mart", kind: .shopping, name: "拼夕夕精选百货", logo: "🛒",
                 rating: 4.6, monthlySales: 92130, deliveryFee: 0, minOrder: 9.9, etaMinutes: 3600,
                 tags: ["9.9 包邮", "百亿补贴", "销量王"]),

            // —— 外卖：奶茶 ——
            Shop(id: "shop-tea", kind: .food, name: "茶语时光·手作茶饮", logo: "🧋",
                 rating: 4.8, monthlySales: 23140, deliveryFee: 3, minOrder: 15, etaMinutes: 28,
                 tags: ["招牌奶茶", "满 30 减 5", "新客立减"]),
            // —— 外卖：炸鸡 ——
            Shop(id: "shop-chicken", kind: .food, name: "咔嗞炸鸡研究所", logo: "🍗",
                 rating: 4.7, monthlySales: 15680, deliveryFee: 4, minOrder: 25, etaMinutes: 32,
                 tags: ["现炸酥脆", "买一送一", "准时达"]),
            // —— 外卖：烧烤 ——
            Shop(id: "shop-bbq", kind: .food, name: "老巷子炭火烧烤", logo: "🍢",
                 rating: 4.6, monthlySales: 9840, deliveryFee: 5, minOrder: 39, etaMinutes: 42,
                 tags: ["炭火现烤", "深夜食堂", "啤酒满减"]),
            // —— 外卖：麻辣烫 ——
            Shop(id: "shop-malatang", kind: .food, name: "热辣麻辣烫·自选", logo: "🌶️",
                 rating: 4.7, monthlySales: 12030, deliveryFee: 3, minOrder: 20, etaMinutes: 30,
                 tags: ["自选大碗", "汤底三选一", "香辣过瘾"]),
            // —— 外卖：日料 ——
            Shop(id: "shop-japan", kind: .food, name: "春町日式料理", logo: "🍣",
                 rating: 4.9, monthlySales: 7320, deliveryFee: 6, minOrder: 49, etaMinutes: 45,
                 tags: ["匠心手作", "新鲜刺身", "招牌寿司"]),
            // —— 外卖：川菜 ——
            Shop(id: "shop-sichuan", kind: .food, name: "蜀香川菜馆", logo: "🥘",
                 rating: 4.7, monthlySales: 8650, deliveryFee: 5, minOrder: 39, etaMinutes: 40,
                 tags: ["地道川味", "麻辣鲜香", "小炒现做"])
        ]
    }

    /// 内置的商品 / 菜品。
    private static func buildGoods() -> [Goods] {
        [
            // ===== 购物 · 数码（果壳数码专营店）=====
            Goods(id: "g-dig-01", shopID: "shop-digital", name: "真无线蓝牙耳机 Pro 降噪版",
                  price: 199.00, sales: 23140, desc: "主动降噪 · 单次续航 8 小时", icon: "🎧"),
            Goods(id: "g-dig-02", shopID: "shop-digital", name: "20000mAh 双向快充充电宝",
                  price: 89.90, sales: 45612, desc: "PD 20W · 能带上飞机", icon: "🔋"),
            Goods(id: "g-dig-03", shopID: "shop-digital", name: "65W 氮化镓多口充电器",
                  price: 79.00, sales: 18203, desc: "手机笔记本一个搞定", icon: "🔌"),
            Goods(id: "g-dig-04", shopID: "shop-digital", name: "磁吸无线充电宝 5000mAh",
                  price: 129.00, sales: 9887, desc: "贴上就充 · 超薄便携", icon: "🧲"),
            Goods(id: "g-dig-05", shopID: "shop-digital", name: "入耳式有线耳机 高清通话",
                  price: 39.90, sales: 30120, desc: "3.5mm 接口 · 戴着不漏音", icon: "🎵"),
            Goods(id: "g-dig-06", shopID: "shop-digital", name: "便携蓝牙小音箱 防水版",
                  price: 159.00, sales: 6721, desc: "IPX7 防水 · 户外露营必备", icon: "🔊"),

            // ===== 购物 · 服饰（南栀女装工作室）=====
            Goods(id: "g-fas-01", shopID: "shop-fashion", name: "珍珠扣针织开衫",
                  price: 158.00, sales: 8231, desc: "软糯亲肤 · 秋冬百搭", icon: "🧥"),
            Goods(id: "g-fas-02", shopID: "shop-fashion", name: "高腰 A 字半身裙",
                  price: 129.00, sales: 12044, desc: "显瘦遮胯 · 一年四季都能穿", icon: "👗"),
            Goods(id: "g-fas-03", shopID: "shop-fashion", name: "条纹长袖打底衫",
                  price: 79.00, sales: 20431, desc: "纯棉透气 · 五色可选", icon: "👚"),
            Goods(id: "g-fas-04", shopID: "shop-fashion", name: "加厚羊毛围巾",
                  price: 89.00, sales: 5673, desc: "柔软不扎脖 · 情侣款", icon: "🧣"),
            Goods(id: "g-fas-05", shopID: "shop-fashion", name: "百搭软底小白鞋",
                  price: 139.00, sales: 15220, desc: "轻便软底 · 悄悄增高 3cm", icon: "👟"),
            Goods(id: "g-fas-06", shopID: "shop-fashion", name: "简约帆布托特包",
                  price: 99.00, sales: 7810, desc: "大容量 · 通勤日常", icon: "👜"),

            // ===== 购物 · 零食（解忧零食铺子）=====
            Goods(id: "g-sna-01", shopID: "shop-snack", name: "每日坚果 30 包装",
                  price: 69.90, sales: 40122, desc: "混合七种坚果 · 独立小包", icon: "🥜"),
            Goods(id: "g-sna-02", shopID: "shop-snack", name: "手工薯片大桶装",
                  price: 29.90, sales: 56120, desc: "原切现炸 · 三种口味", icon: "🥔"),
            Goods(id: "g-sna-03", shopID: "shop-snack", name: "黄油曲奇礼盒",
                  price: 45.00, sales: 12330, desc: "送礼自留都合适", icon: "🍪"),
            Goods(id: "g-sna-04", shopID: "shop-snack", name: "芒果干 500g",
                  price: 24.90, sales: 22310, desc: "酸甜有嚼劲 · 无添加", icon: "🥭"),
            Goods(id: "g-sna-05", shopID: "shop-snack", name: "混合果干每日份",
                  price: 39.90, sales: 8120, desc: "办公室下午茶首选", icon: "🍇"),
            Goods(id: "g-sna-06", shopID: "shop-snack", name: "手工黑糖麻薯",
                  price: 19.90, sales: 19020, desc: "软糯拉丝 · 现做现发", icon: "🍡"),

            // ===== 购物 · 家居（拾光家居生活馆）=====
            Goods(id: "g-hom-01", shopID: "shop-home", name: "无火香薰礼盒",
                  price: 88.00, sales: 6540, desc: "持久留香 · 礼盒装", icon: "🕯️"),
            Goods(id: "g-hom-02", shopID: "shop-home", name: "折叠收纳箱 大号",
                  price: 59.00, sales: 14320, desc: "加厚牛津布 · 可叠放", icon: "📦"),
            Goods(id: "g-hom-03", shopID: "shop-home", name: "北欧风陶瓷花瓶",
                  price: 76.00, sales: 4210, desc: "拍照好看 · 三色可选", icon: "🏺"),
            Goods(id: "g-hom-04", shopID: "shop-home", name: "珊瑚绒毛毯 双人款",
                  price: 129.00, sales: 9820, desc: "午睡盖毯 · 不掉毛", icon: "🛏️"),
            Goods(id: "g-hom-05", shopID: "shop-home", name: "桌面木质收纳架",
                  price: 45.00, sales: 5320, desc: "简约原木 · 免安装", icon: "🗄️"),
            Goods(id: "g-hom-06", shopID: "shop-home", name: "硅藻泥吸水地垫",
                  price: 39.90, sales: 20110, desc: "速干防滑 · 好打理", icon: "🧽"),

            // ===== 购物 · 百货（拼夕夕精选百货）=====
            Goods(id: "g-mar-01", shopID: "shop-mart", name: "抽纸 30 包整箱",
                  price: 9.90, sales: 81240, desc: "加厚不掉屑 · 原木浆", icon: "🧻"),
            Goods(id: "g-mar-02", shopID: "shop-mart", name: "加厚背心垃圾袋 100 只",
                  price: 6.90, sales: 65210, desc: "加厚不易破 · 大号", icon: "🗑️"),
            Goods(id: "g-mar-03", shopID: "shop-mart", name: "洗衣凝珠 52 颗",
                  price: 19.90, sales: 33120, desc: "一颗一桶 · 深层去渍", icon: "🧼"),
            Goods(id: "g-mar-04", shopID: "shop-mart", name: "一次性洗脸巾 3 卷",
                  price: 9.90, sales: 45210, desc: "纯棉亲肤 · 干湿两用", icon: "🧴"),
            Goods(id: "g-mar-05", shopID: "shop-mart", name: "不锈钢晾衣架 10 个装",
                  price: 12.90, sales: 15032, desc: "防滑防风 · 加粗耐用", icon: "🧷"),

            // ===== 外卖 · 奶茶（茶语时光·手作茶饮）=====
            Goods(id: "g-tea-01", shopID: "shop-tea", name: "招牌手作珍珠奶茶",
                  price: 18.00, sales: 33120, desc: "现煮珍珠 · 建议三分糖", icon: "🧋"),
            Goods(id: "g-tea-02", shopID: "shop-tea", name: "西柚百香果茶",
                  price: 16.00, sales: 18230, desc: "清爽解腻 · 果肉满满", icon: "🍹"),
            Goods(id: "g-tea-03", shopID: "shop-tea", name: "生椰拿铁",
                  price: 22.00, sales: 24110, desc: "椰香浓郁 · 微苦回甘", icon: "☕"),
            Goods(id: "g-tea-04", shopID: "shop-tea", name: "多肉葡萄冰沙",
                  price: 26.00, sales: 9870, desc: "整颗葡萄 · 夏日限定", icon: "🍇"),

            // ===== 外卖 · 炸鸡（咔嗞炸鸡研究所）=====
            Goods(id: "g-chk-01", shopID: "shop-chicken", name: "半只韩式炸鸡 + 可乐",
                  price: 45.00, sales: 15230, desc: "甜辣酥脆 · 送可乐", icon: "🍗"),
            Goods(id: "g-chk-02", shopID: "shop-chicken", name: "全家桶 8 块装",
                  price: 59.00, sales: 8730, desc: "三种口味拼 · 够 3 人吃", icon: "🍗"),
            Goods(id: "g-chk-03", shopID: "shop-chicken", name: "香辣鸡翅 6 只",
                  price: 32.00, sales: 12010, desc: "外酥里嫩 · 微微辣", icon: "🍖"),
            Goods(id: "g-chk-04", shopID: "shop-chicken", name: "薯条配鸡米花拼盘",
                  price: 28.00, sales: 9040, desc: "追剧标配 · 送蘸酱", icon: "🍟"),

            // ===== 外卖 · 烧烤（老巷子炭火烧烤）=====
            Goods(id: "g-bbq-01", shopID: "shop-bbq", name: "羊肉串 10 串",
                  price: 39.00, sales: 8210, desc: "炭火现烤 · 孜然味", icon: "🍢"),
            Goods(id: "g-bbq-02", shopID: "shop-bbq", name: "烤茄子配烤生蚝",
                  price: 45.00, sales: 5430, desc: "蒜蓉香辣 · 鲜嫩多汁", icon: "🦪"),
            Goods(id: "g-bbq-03", shopID: "shop-bbq", name: "烤鸡翅中 6 只",
                  price: 36.00, sales: 6720, desc: "蜜汁微辣 · 外焦里嫩", icon: "🍗"),
            Goods(id: "g-bbq-04", shopID: "shop-bbq", name: "锡纸金针菇",
                  price: 18.00, sales: 9130, desc: "蒜香浓郁 · 解腻", icon: "🍄"),

            // ===== 外卖 · 麻辣烫（热辣麻辣烫·自选）=====
            Goods(id: "g-mlt-01", shopID: "shop-malatang", name: "自选麻辣烫 大碗",
                  price: 26.00, sales: 14230, desc: "20 多种配菜任选", icon: "🌶️"),
            Goods(id: "g-mlt-02", shopID: "shop-malatang", name: "番茄汤底麻辣烫",
                  price: 28.00, sales: 8720, desc: "不辣也能吃 · 酸甜开胃", icon: "🍅"),
            Goods(id: "g-mlt-03", shopID: "shop-malatang", name: "麻辣拌 双人份",
                  price: 42.00, sales: 4310, desc: "干拌更香 · 微辣", icon: "🥗"),
            Goods(id: "g-mlt-04", shopID: "shop-malatang", name: "酸辣粉 单人餐",
                  price: 16.00, sales: 11230, desc: "酸辣开胃 · 红薯粉", icon: "🍜"),

            // ===== 外卖 · 日料（春町日式料理）=====
            Goods(id: "g-jpn-01", shopID: "shop-japan", name: "三文鱼刺身 8 片",
                  price: 58.00, sales: 6210, desc: "冰鲜直达 · 厚切", icon: "🍣"),
            Goods(id: "g-jpn-02", shopID: "shop-japan", name: "招牌寿司拼盘 12 贯",
                  price: 68.00, sales: 4830, desc: "现做现送 · 四色搭配", icon: "🍱"),
            Goods(id: "g-jpn-03", shopID: "shop-japan", name: "日式豚骨拉面",
                  price: 42.00, sales: 9130, desc: "浓汤 · 配溏心蛋", icon: "🍜"),
            Goods(id: "g-jpn-04", shopID: "shop-japan", name: "蟹柳加州卷 8 块",
                  price: 36.00, sales: 5540, desc: "清爽卷 · 海苔香", icon: "🍙"),

            // ===== 外卖 · 川菜（蜀香川菜馆）=====
            Goods(id: "g-sch-01", shopID: "shop-sichuan", name: "小炒黄牛肉",
                  price: 46.00, sales: 7320, desc: "现炒现做 · 下饭神器", icon: "🥩"),
            Goods(id: "g-sch-02", shopID: "shop-sichuan", name: "麻婆豆腐配米饭",
                  price: 26.00, sales: 12310, desc: "麻辣鲜香 · 超级下饭", icon: "🍲"),
            Goods(id: "g-sch-03", shopID: "shop-sichuan", name: "宫保鸡丁",
                  price: 38.00, sales: 6320, desc: "酸甜微辣 · 花生脆", icon: "🥡"),
            Goods(id: "g-sch-04", shopID: "shop-sichuan", name: "水煮肉片 大份",
                  price: 52.00, sales: 4110, desc: "麻辣过瘾 · 分量足", icon: "🥘")
        ]
    }
}

// MARK: - 进网盘备份（已登记进 BackupService.stores()）

/// 让「真实生活」的订单和客服记录跟别的数据一起进网盘。
///
/// ⭐ 2026-10：已经登记进 `BackupService.stores()`（`RealLifeStore.shared`），
///    所以搬家时它会来问这里要数据；`backupName = "reallife"` 与 `label()` 对得上。
extension RealLifeStore: BackupableStore {

    /// 包里这段的名字。**定了就别改** —— 改了老备份恢复不回来。
    var backupName: String { "reallife" }

    /// 导出**所有人的**订单 / 客服 —— 搬家要搬的是全部，不只当前这个。
    func exportBackup() throws -> Data {
        stash()
        let flat = byOwner.reduce(into: [String: OwnerData]()) { result, pair in
            result[pair.key.uuidString] = pair.value
        }
        return try JSONEncoder().encode(Archive(byOwner: flat))
    }

    func importBackup(_ data: Data) throws {
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        // ⚠️ 导入全程禁写：中途 `PersonaStore.broadcastSwitch` 会调 `setOwner`，
        //    那一下要是允许 `stash()`，刚搬进来的订单当场被旧机器的顶掉。
        loading = true
        defer { loading = false }

        if let imported = archive.byOwner, !imported.isEmpty {
            byOwner = imported.reduce(into: [:]) { result, pair in
                guard let id = UUID(uuidString: pair.key) else { return }
                result[id] = pair.value
            }
        } else if archive.orders != nil || archive.chats != nil {
            // 老备份（单人）→ 认到现在的 active（`PersonaStore` 先导完通讯录，owner 已就位）。
            let fallback = PersonaStore.shared.activeID ?? PersonaStore.shared.contacts.first?.id
            if let fallback {
                byOwner[fallback] = OwnerData(orders: archive.orders ?? [],
                                              chats: archive.chats ?? [])
            }
        }

        let current = owner.flatMap { byOwner[$0] } ?? OwnerData()
        allOrders = current.orders
        allChats = current.chats
        writeArchive()
    }
}
