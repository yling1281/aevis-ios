import ActivityKit
import SwiftUI
import WidgetKit

/// Aevis 实时活动（灵动岛）扩展。
///
/// 两种形态：
///   · **挂机态**（`state.text` 为空）：只留一个不起眼的小圆点，表示「ta在」。
///   · **有消息态**：显示 ta的名字 + ta这句话（截断）+ 时间。
///
/// ⚠️ 灵动岛那几种视图（展开区若干 + `compactLeading` + `compactTrailing` +
///    `minimal`）**一个都不能少** —— 少一个系统可能干脆不显示这张卡。
///
/// ⚠️ 这里的 `Text` 一律**不解析 markdown**（单行字面量走 `Text(String)`），
///    所以文案里**不要**写 `**加粗**`，会原样显示星号（R17）。
///
/// ⚠️ 这是**扩展 target**，读不到主 App 的 `Pronoun`（人设性别）—— 所以这里指代 ta 的词
///    一律**写死小写 `ta`**，**不会**跟着人设性别变（女 / 男都还是 ta）。这是跨 target 的已知限制；
///    要让它跟着人设走，只能由主 App 在发 Activity 时把词算好、塞进 `ContentState` 再传进来。
@main
struct AevisLiveWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AevisMessageAttributes.self) { context in
            // 锁屏 / 横幅上的那张卡。
            //
            // ⚠️ 强制 `.dark`：锁屏上这张卡的默认配色**不一定是深色**，
            //    而我们的底色是深的（下面 `activityBackgroundTint`）——
            //    不钉死的话 `.primary` 可能解析成黑字，**黑底黑字**。
            //    （灵动岛那边不用管：它的背景恒为黑。）
            AevisLockScreen(context: context)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color(red: 0.10, green: 0.10, blue: 0.12))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // ——— 展开区（灵动岛拉长之后那几块）———
                DynamicIslandExpandedRegion(.leading) {
                    AevisMarker(active: !AevisLiveWidget.isIdle(context.state))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AevisTime(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    AevisTitle(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AevisText(state: context.state)
                }
            } compactLeading: {
                // 灵动岛横向那种形态：左边一个小标记
                AevisMarker(active: !AevisLiveWidget.isIdle(context.state))
            } compactTrailing: {
                // 右边：有消息时也放个小标记；挂机时留空（不显眼）
                AevisCompactTail(state: context.state)
            } minimal: {
                // 最小形态（同时有别的活动时）：只留一个点
                AevisMarker(active: !AevisLiveWidget.isIdle(context.state))
            }
            .keylineTint(Color(red: 0.494, green: 0.420, blue: 0.847))
        }
    }

    /// 「挂机态」= ta这句话是空的。
    static func isIdle(_ state: AevisMessageAttributes.ContentState) -> Bool {
        state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 零件

/// 那个「ta在」的小标记。挂机时只是一个小灰点，有消息时是粉色、稍大一点。
private struct AevisMarker: View {
    let active: Bool

    var body: some View {
        // 原来就是一个 9pt 的粉圆点，放在黑底上只是「有个东西」，
        // 看不出是谁、也看不出状态。换成「气泡 + 光晕」：
        //   · 气泡本身用描边（黑底上填充白会糊），
        //   · 活跃时外面套一圈 18% 白的柔光，远看像在呼吸，
        //   · 挂机态缩到 65% 并降到 40% 不透明度，存在感很弱。
        ZStack {
            if active {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 22, height: 22)
            }
            Canvas { ctx, s in
                let w = s.width, h = s.height
                let st = StrokeStyle(lineWidth: max(1.2, w * 0.10),
                                     lineCap: .round, lineJoin: .round)
                // 对话气泡：圆角方 + 左下小尾巴
                var p = Path()
                let inset = w * 0.14
                p.addRoundedRect(
                    in: CGRect(x: inset, y: inset, width: w - inset * 2, height: (h - inset * 2) * 0.74),
                    cornerSize: CGSize(width: w * 0.26, height: w * 0.26)
                )
                p.move(to: CGPoint(x: w * 0.30, y: h * 0.62))
                p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.86))
                p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.68))
                ctx.stroke(p, with: .color(.white.opacity(active ? 1.0 : 0.42)), style: st)
            }
            .frame(width: active ? 20 : 16, height: active ? 20 : 16)
        }
        .frame(width: 24, height: 24)
    }
}

/// ta的名字（挂机态不显示）。
private struct AevisTitle: View {
    let state: AevisMessageAttributes.ContentState

    var body: some View {
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if AevisLiveWidget.isIdle(state) {
            EmptyView()
        } else {
            Text(name.isEmpty ? "ta" : name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// ta的那句话（挂机态显示一句「ta在」的说明，有消息时显示正文、截断到两行）。
private struct AevisText: View {
    let state: AevisMessageAttributes.ContentState

    var body: some View {
        if AevisLiveWidget.isIdle(state) {
            // 挂机态**不写任何文案**。
            // 以前这里印一句「在，随时找我」——用户 2026-11-11 明确说默认不要这句：
            // 挂机就该是安静的，别替他说话。名字上面已经有了，这里留空。
            EmptyView()
        } else {
            Text(state.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

/// 时间（挂机态不显示）。
private struct AevisTime: View {
    let state: AevisMessageAttributes.ContentState

    var body: some View {
        if AevisLiveWidget.isIdle(state) {
            EmptyView()
        } else {
            Text(state.at, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// 紧凑形态右边那一小块。
private struct AevisCompactTail: View {
    let state: AevisMessageAttributes.ContentState

    var body: some View {
        if AevisLiveWidget.isIdle(state) {
            EmptyView()
        } else {
            AevisMarker(active: true)
        }
    }
}

/// 锁屏 / 横幅上的卡片。（⚠️ 一个 `HStack` 里只有一个 `Spacer`。）
private struct AevisLockScreen: View {
    let context: ActivityViewContext<AevisMessageAttributes>

    var body: some View {
        HStack(spacing: 10) {
            AevisMarker(active: !AevisLiveWidget.isIdle(context.state))

            VStack(alignment: .leading, spacing: 2) {
                AevisTitle(state: context.state)
                AevisText(state: context.state)
            }

            Spacer(minLength: 0)

            AevisTime(state: context.state)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
