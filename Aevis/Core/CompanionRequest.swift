import SwiftUI

/// 「TA 想主动做点什么」—— 打电话、看你的屏幕、一起听歌。
///
/// ## 用户要的（2026-09-26）
/// 「AI 也可以主动的去申请……屏幕共享之类的，**我们能用的东西它都能自动申请**」。
///
/// ## 为什么中间一定要夹一道"你点头"
/// 不是我们保守，是 **iOS 上本来就做不到**：
/// - 打电话要麦克风 + 语音识别权限，**而且突然响起来会吓人**；
/// - 屏幕共享必须走系统那个录屏弹窗，**只有你手指点得动**；
/// - 一起听会开始出声。
///
/// 所以设计成：**她提出 → 界面上浮出一条申请 → 你点了才真的开始**。
/// 这跟那条最高优先的产品原则也是一路的（不拿我们的标准去安排用户的标准）——
/// 她想做什么尽管提，做不做由你定。
///
/// 顺带一个好处：她"提了什么、你为什么点了同意"这件事本身就有陪伴感，
/// 比默默开始更像真的有人在问你。
final class CompanionRequest: ObservableObject {

    static let shared = CompanionRequest()

    /// 她想做的事都在这儿登记。加新能力就往这个枚举里加一条。
    enum Kind: String, Identifiable {
        case call
        case screenShare
        case listenTogether

        var id: String { rawValue }

        /// 界面上那句主文案 —— 用她的口吻，不是系统提示的口吻。
        var title: String {
            switch self {
            case .call: return "想给你打个电话"
            case .screenShare: return "想看看你的屏幕"
            case .listenTogether: return "想和你一起听会儿歌"
            }
        }

        /// 同意按钮上写什么。**别写"确定/取消"** —— 那像系统权限弹窗。
        var acceptTitle: String {
            switch self {
            case .call: return "接听"
            case .screenShare: return "让她看"
            case .listenTogether: return "一起听"
            }
        }

        var symbol: String {
            switch self {
            case .call: return "phone.arrow.up.right"
            case .screenShare: return "rectangle.on.rectangle"
            case .listenTogether: return "music.note"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var kind: Kind
        /// 她自己写的理由（一句话）。空着就不显示。
        var reason: String
        var at = Date()
    }

    /// 现在挂着的那条申请。
    ///
    /// **同一时刻只留一条** —— 攒一堆申请比不弹还烦，而且她会显得很吵。
    /// 正在挂着的时候再来申请就不覆盖（先来后到，你把手上这条处理完再说）。
    @Published var pending: Item?

    /// 上一次被拒绝的是哪种，多久之前 —— 短时间内不让她反复提同一件事。
    private var lastDeclined: (kind: Kind, at: Date)?

    private init() {}

    /// 她提出申请。
    func ask(_ kind: Kind, reason: String) {
        guard pending == nil else { return }

        // 你刚说过"不用"，隔几秒又弹一次，那就是骚扰了。
        if let lastDeclined, lastDeclined.kind == kind,
           Date().timeIntervalSince(lastDeclined.at) < 90 {
            return
        }

        pending = Item(
            kind: kind,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// 你点了同意。返回被同意的那件事（界面据此真的去执行），并清掉这条。
    @discardableResult
    func accept() -> Kind? {
        guard let item = pending else { return nil }
        pending = nil
        return item.kind
    }

    /// 你点了"不用了"。
    func decline() {
        if let item = pending {
            lastDeclined = (item.kind, Date())
        }
        pending = nil
    }
}
