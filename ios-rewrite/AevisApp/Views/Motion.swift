import SwiftUI

/// 统一的动效约定（2026-11-25）—— 别再各处手写 duration / delay。
///
/// 用户明确要求的三件事：
/// 1. **页面转场从右往左**（不是上下）。上下滑像模态弹窗，右进左出才是"翻页"；
/// 2. **开屏元素依次轻微上跳**（stagger，每项差 0.05s，位移 14pt，不是整块一起淡入）；
/// 3. **数字变化要滚动过渡**（见 `AnimatedNumber`，那边是逐帧插值）。
enum AEMotion {

    /// 页面切换：新页面从右侧滑入 + 淡入，旧页面向左侧滑出 + 淡出。
    ///
    /// 为什么不用 `.opacity` 单淡入：用户要的是"翻页感"，纯淡入会像刷新。
    /// 为什么 removal 往左：与 insertion 同向，视觉上是一条连续的运动轨迹（内容被"推走"）。
    static var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    /// 页面切换的动画曲线：短、跟手，不做弹跳（弹跳在整屏位移上会晕）。
    static var pageAnimation: Animation { .easeInOut(duration: 0.22) }

    /// 反向切页（从第一个 tab 切回前一个）：新页从**左**进、旧页往**右**出。
    /// 不加这个，往回切也会"从右进"，观感像又往前走了一步。
    static var pageTransitionBackward: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    /// 开屏 / 列表元素上跳的基准时长
    static var riseAnimation: Animation {
        .spring(response: 0.5, dampingFraction: 0.86)
    }

    /// 第 index 个元素的延迟：0 / 0.05 / 0.10 …
    static func staggerDelay(_ index: Int, step: Double = 0.05) -> Double {
        Double(max(index, 0)) * step
    }
}

/// 元素依次上跳（位移 14pt + 淡入，按 index 递增延迟）。
///
/// 用法：给同一屏里从上到下的卡片依次 `.staggerIn(0)` `.staggerIn(1)` …
/// 注意只加在**首屏可见**的卡片上：滚动列表里加会让"滚动到才出现"变成"滚动到才跳"，
/// 观感反而像卡顿。
struct StaggerIn: ViewModifier {
    let index: Int
    var distance: CGFloat = 14

    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : distance)
            .onAppear {
                guard !shown else { return }
                withAnimation(AEMotion.riseAnimation.delay(AEMotion.staggerDelay(index))) {
                    shown = true
                }
            }
    }
}

extension View {
    /// 依次上跳入口：`card.staggerIn(2)`
    func staggerIn(_ index: Int, distance: CGFloat = 14) -> some View {
        modifier(StaggerIn(index: index, distance: distance))
    }
}
