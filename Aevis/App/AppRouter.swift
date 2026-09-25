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

    @Published var showSettings = false
    @Published var showMoments = false
    @Published var showTogether = false
    @Published var showCall = false

    private init() {}
}
