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
            .keylineTint(Color.pink)
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
        Circle()
            .fill(active ? Color.pink : Color.gray.opacity(0.5))
            .frame(width: active ? 9 : 6, height: active ? 9 : 6)
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
            Text("在，随时找我")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
