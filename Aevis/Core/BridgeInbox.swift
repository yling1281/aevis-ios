import Foundation

/// 快捷指令想「让界面做点什么」时的中转站。
///
/// 为什么需要它：`AevisBridge` 是纯逻辑，它能让数据入库、能调工具，
/// 但**没法弹界面**（弹出通话、打开一起听这些是 View 的事）。
/// 所以桥把意图放在这里，聊天页看到了就执行。
///
/// 每个字段都是「放进去 → 界面取走 → 置回 nil」的一次性信号，
/// 不做队列 —— 快捷指令一次只发一条，排队反而会积压出怪行为。
final class BridgeInbox: ObservableObject {

    static let shared = BridgeInbox()

    /// 快捷指令送来一句话要问她。聊天页取走后会自动发出去。
    @Published var ask: String?

    /// 弹出实时通话界面。
    @Published var openCall = false

    /// 弹出一起听面板。
    @Published var openListen = false

    /// 让她放这首歌（歌名或关键词）。
    @Published var playQuery: String?

    private init() {}
}
