import Foundation

/// 全局的界面跳转信号。
///
/// 为什么要有它：设置、朋友圈、一起听、通话这几个面板原来都挂在聊天页上，
/// 而聊天页现在是「从会话列表点进去」的**二级页面** ——
/// 可截图自检需要在**启动时**就把设置打开，那时聊天页根本还没出现。
///
/// 所以把这些「要弹哪个面板」提到根视图上，谁都能发这个信号：
/// 二级页面能发，根视图也能发，截图自检的启动参数也走这里。
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    // ⚠️ 这几个 `didSet` 是**全量操作埋点**的一半（用户 2026-09-26 要求
    // 「不管点了哪个按键都要记起来」）：所有弹层/全屏都得经过这里，
    // 在这一处记 = 这几个面板的开关一个都不会漏。
    // 各页面自己的出现走 `.aevisScreen(_:)`。
    @Published var showSettings = false {
        didSet { track("设置", showSettings) }
    }
    @Published var showMoments = false {
        didSet { track("朋友圈", showMoments) }
    }
    @Published var showTogether = false {
        didSet { track("一起听", showTogether) }
    }
    @Published var showCall = false {
        didSet { track("通话", showCall) }
    }
    /// 全屏播放器（仿网易云那个封面转盘）。**在列表里点一首歌就弹它。**
    @Published var showPlayer = false {
        didSet { track("播放器", showPlayer) }
    }

    /// 打开设置时**直接落到哪一张卡**（nil 就是完整的设置页）。
    ///
    /// 「她申请看屏幕」点同意之后要用这条：iOS 不允许 App 自己开录屏，
    /// 只有陪伴卡里那个系统按钮点得动，所以得把人送到那一张卡前面。
    @Published var settingsFocus: String?

    private func track(_ name: String, _ opened: Bool) {
        BlackBox.log(opened ? "⇢ 打开 \(name)" : "⇠ 关掉 \(name)")
    }

    private init() {}
}
