import SwiftUI

/// 「气泡」设置卡片 —— **两侧各改各的**。
///
/// 用户原话：「AI 的气泡也要改」「对方的气泡也能归我改」。
/// 所以这里不是一个全局气泡风格，而是「我发的」和「TA 发的」两套，
/// 样式、颜色、圆角都能分开调，下面还有实时预览。
struct BubbleSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("气泡")

            section(heading: "我发的", look: $settings.myBubble, isMine: true)
            rule

            section(heading: "TA 发的", look: $settings.aiBubble, isMine: false)
            rule

            VStack(alignment: .leading, spacing: 0) {
                toggleRow("显示我的头像", subtitle: "关掉之后只有气泡，更干净", isOn: $settings.showMyAvatar)
                toggleRow("显示 TA 的头像", subtitle: "关掉之后 TA 的话也不带头像", isOn: $settings.showAiAvatar)
            }
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 一侧

    private func section(heading: String, look: Binding<BubbleLook>, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(.aevis(14.5, weight: .medium))
                .foregroundStyle(.primary)

            Picker(heading, selection: look.style) {
                ForEach(BubbleStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Text(look.wrappedValue.style.explanation)
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 9) {
                label("颜色")
                HStack(spacing: 12) {
                    // 第一档是「跟随主题色」，用一个渐变圆表示
                    Button {
                        look.wrappedValue.colorIndex = -1
                    } label: {
                        Circle()
                            .fill(
                                AngularGradient(
                                    colors: AppSettings.accentPalette,
                                    center: .center
                                )
                            )
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle().strokeBorder(
                                    look.wrappedValue.colorIndex < 0
                                        ? Color.primary.opacity(0.85)
                                        : Color.primary.opacity(0.15),
                                    lineWidth: 2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跟随主题色")

                    ForEach(Array(AppSettings.bubblePalette.enumerated()), id: \.offset) { index, color in
                        Button {
                            look.wrappedValue.colorIndex = index
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle().strokeBorder(
                                        look.wrappedValue.colorIndex == index
                                            ? Color.primary.opacity(0.85)
                                            : Color.primary.opacity(0.15),
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppSettings.bubbleColorNames[index])
                    }
                    Spacer(minLength: 0)
                }

                Text("当前：\(settings.bubbleColorName(look.wrappedValue))")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("圆角")
                        .font(.aevis(14))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", look.wrappedValue.cornerScale * 100))
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                Slider(value: look.cornerScale, in: 0.5...1.8, step: 0.05)
            }

            preview(look.wrappedValue, isMine: isMine)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    /// 实时预览。用的是聊天里同一个气泡组件，所以看到的就是实际效果。
    private func preview(_ look: BubbleLook, isMine: Bool) -> some View {
        let color = settings.bubbleColor(look)
        let corner = max(6, 18 * CGFloat(settings.cornerScale * look.cornerScale))

        return VStack(alignment: .leading, spacing: 6) {
            Text("预览")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                if isMine { Spacer(minLength: 40) }

                AevisBubble(
                    text: isMine ? "在干嘛呢" : "刚到家，有点累",
                    look: look,
                    color: color,
                    corner: corner,
                    fontSize: 15.5,
                    horizontalPadding: 14,
                    verticalPadding: 10,
                    plainTextColor: settings.fontColor
                )

                if !isMine { Spacer(minLength: 40) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - 零件

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5))
            .foregroundStyle(.secondary)
    }

    private func toggleRow(_ text: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
