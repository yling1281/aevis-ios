import SwiftUI

/// 通用分段控件（SwiftUI 版安卓 `SegmentedTabs.kt`）。
///
/// 三层：① 浅色底槽（圆角 squircle 13）；② 选中态深藏青胶囊，spring 平滑平移；
/// ③ 每层文字（选中白色粗体、未选中灰色）。平移时胶囊做 squash & stretch：
/// 用「目标位置」与「动画插值位置」之差（lag）算 scaleX/scaleY，停下 spring 回弹。
///
/// 严格固定高度 38pt —— 安卓踩过「指示块 fillMaxHeight 撑满全屏」的坑，
/// 这里 `.frame(height: 38)` 约束，指示块只按段宽绘制，绝不撑破。
///
/// 用法：`SegmentedTabs(tabs: ["畅聊","小鱼干"], selected: $tab).frame(width: 300)`
struct SegmentedTabs: View {
    let tabs: [String]
    @Binding var selected: Int

    private let height: CGFloat = 38
    private let pad: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            if !tabs.isEmpty {
                let itemW = max(0, (geo.size.width - pad * 2) / CGFloat(tabs.count))
                let pos = CGFloat(min(max(selected, 0), tabs.count - 1))

                ZStack(alignment: .leading) {
                    // ① 底槽
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.primary.opacity(0.055))

                    // ② 滑动胶囊：target 立即跳新值、pos 由 spring 插值，两者之差驱动形变
                    SlidingPill(
                        target: pos, pos: pos,
                        itemW: itemW, pad: pad, height: height
                    )

                    // ③ 文字层
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { i, name in
                            Text(name)
                                .font(.system(size: 13,
                                              weight: selected == i ? .semibold : .regular))
                                .foregroundStyle(selected == i ? .white : Color.primary.opacity(0.5))
                                .lineLimit(1)
                                .frame(width: itemW, height: height - pad * 2)
                                .contentShape(Rectangle())
                                .onTapGesture { if selected != i { selected = i } }
                        }
                    }
                    .padding(.leading, pad)
                }
                .padding(pad)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .frame(height: height)
    }
}

/// 滑动胶囊：遵循 `Animatable`，SwiftUI 在事务动画中对 `animatableData`（pos）
/// 从旧值插值到新值并逐帧重绘 body；`target` 是普通存储属性，立即跳到新值。
/// lag = |target - pos|，对齐安卓 sx=1+lag*0.10 / sy=1-lag*0.06。
private struct SlidingPill: View, Animatable {
    let target: CGFloat
    var pos: CGFloat
    let itemW: CGFloat
    let pad: CGFloat
    let height: CGFloat

    var animatableData: CGFloat {
        get { pos }
        set { pos = newValue }
    }

    var body: some View {
        let lag = min(abs(target - pos), 1)
        let sx = 1 + lag * 0.10
        let sy = 1 - lag * 0.06
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(AE.accentDeep)
            .frame(width: itemW, height: height - pad * 2)
            .scaleEffect(x: sx, y: sy)
            .offset(x: pad + itemW * pos)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: target)
    }
}
