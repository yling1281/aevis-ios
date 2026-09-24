import SwiftUI

/// 「朋友圈」设置卡片：开关 + 频率 + 入口。
struct MomentsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var moments = MomentStore.shared

    @State private var showMoments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("朋友圈")

            toggleRow(
                "让她自己发",
                subtitle: "打开之后她会时不时发一条，你打开 App 时补上",
                isOn: $settings.momentsEnabled
            )

            if settings.momentsEnabled {
                rule

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("一天大概几条")
                            .font(.aevis(14))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(settings.momentsPerDay) 条")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.momentsPerDay) },
                            set: { settings.momentsPerDay = Int($0.rounded()) }
                        ),
                        in: 1...6,
                        step: 1
                    )
                    Text("做不到精确到点 —— 后台跑不了模型，所以是按「距上一条够久了就补一条」来算。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            rule

            // ——— 她的反应 ———
            // 用户要求：我发出去之后她会自动回复 + 点赞，
            // 而且要能控制回复的条数，不然容易刷屏。

            toggleRow(
                "我发完她会来互动",
                subtitle: "点赞、评论，像真的有人在看你的朋友圈",
                isOn: $settings.momentAutoReact
            )

            if settings.momentAutoReact {
                rule

                toggleRow(
                    "给我点赞",
                    subtitle: "关掉就只评论不点赞",
                    isOn: $settings.momentLikeMine
                )

                rule

                sliderRow(
                    title: "一条动态最多评论几条",
                    value: Binding(
                        get: { Double(settings.momentMaxComments) },
                        set: { settings.momentMaxComments = Int($0.rounded()) }
                    ),
                    range: 1...3,
                    suffix: "条",
                    note: "到上限就不再评了，免得一口气刷一屏。"
                )
            }

            rule

            toggleRow(
                "我评论她，她回我",
                subtitle: "你在她动态下留言，她立刻回一句",
                isOn: $settings.momentAutoReply
            )

            if settings.momentAutoReply {
                rule

                sliderRow(
                    title: "一条留言最多回几条",
                    value: Binding(
                        get: { Double(settings.momentMaxReplies) },
                        set: { settings.momentMaxReplies = Int($0.rounded()) }
                    ),
                    range: 1...3,
                    suffix: "条",
                    note: "按「你上一次留言之后」算 —— 你每留一条言她都会回，但不会自己跟自己说个不停。"
                )
            }

            rule

            // ——— 私信 ———
            // 用户要求：「有些还会私信主动联系你」= 不是每次，按概率来。

            toggleRow(
                "有时候会私信找我",
                subtitle: "不只在评论区说，而是直接发消息过来，聊天里能看到",
                isOn: $settings.momentDMEnabled
            )

            if settings.momentDMEnabled {
                rule

                sliderRow(
                    title: "私信的概率",
                    value: $settings.momentDMChance,
                    range: 0.1...1.0,
                    suffix: "%",
                    isPercent: true,
                    note: "不是每次都私信 —— 真人也常常只是点个赞就走了。开了 Bark 的话，她私信你时会一起推一条。"
                )
            }

            rule

            Button {
                showMoments = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.aevis(15, weight: .medium))
                        .foregroundStyle(AppSettings.shared.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("打开朋友圈")
                            .font(.aevis(15.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(moments.moments.isEmpty
                             ? "还没有动态"
                             : "\(moments.moments.count) 条动态")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.aevis(13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let status = moments.statusLine {
                Text(status)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 11)
            }
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(isPresented: $showMoments) {
            MomentsView()
        }
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

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        isPercent: Bool = false,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.aevis(14))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(isPercent
                     ? "\(Int((value.wrappedValue * 100).rounded()))%"
                     : "\(Int(value.wrappedValue.rounded())) \(suffix)")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: isPercent ? 0.05 : 1)
            Text(note)
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
