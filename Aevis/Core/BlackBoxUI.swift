import SwiftUI

/// 把「进了哪个页面」「点了哪个按钮」自动记进黑匣子。
///
/// ## 用户的要求（2026-09-26）
/// 「假如我点了这个『群规则常见问题』跳转了，这个要记起来，
/// 就是**点了哪个按键都要记起来**。我切换了聊天、切换了发现、切换了我的，
/// 这些都要记起来。**不管点了哪个按键都要记起来**。」
///
/// ## 为什么不是"全自动"
/// SwiftUI 的 `Button` 用的是自己的手势，系统层面**没有**一个"某个按钮被点了"的
/// 统一通知（UIKit 的 `sendAction` 那套对 SwiftUI 按钮无效）。
/// 所以只能靠两层：
/// 1. **自动**：tab 切换、弹层/全屏（在 `AppRouter` 里统一挂）、每个页面出现时
/// 2. **显式**：按钮上挂 `.aevisTap("名字")`，或者干脆用 `LoggedButton`
///
/// ⚠️ **加了新按钮记得挂一个** —— 不然将来查现场时，日志上就断在那一屏了。
extension View {

    /// 进这个页面时记一笔。挂在页面根视图上。
    func aevisScreen(_ name: String) -> some View {
        onAppear { BlackBox.screen(name) }
    }

    /// 点这个按钮 / 这一行时记一笔。
    ///
    /// ⚠️ 用 `simultaneousGesture` 而不是 `onTapGesture`：
    /// `onTapGesture` 会**抢走**按钮自己的点击，加上去按钮就点不动了。
    /// `simultaneous` 是"同时识别"，两边都会跑。
    func aevisTap(_ name: String) -> some View {
        simultaneousGesture(TapGesture().onEnded { BlackBox.tap(name) })
    }
}

/// 带日志的按钮 —— 用它替掉 `Button`，点击**一定会**先记一笔再执行。
///
/// 比 `.aevisTap` 稳：不依赖"手势能不能同时识别"这件没法验证的事。
/// 新写的按钮尽量用它；老的用 `.aevisTap` 补。
struct LoggedButton<Label: View>: View {
    private let name: String
    private let action: () -> Void
    private let label: Label

    init(_ name: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.name = name
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            BlackBox.tap(name)
            action()
        } label: {
            label
        }
    }
}
