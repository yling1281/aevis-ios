import PhotosUI
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「朋友圈」设置卡片：开关 + 频率 + 入口 + **个性化**。
struct MomentsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var moments = MomentStore.shared

    @State private var showMoments = false

    // ——— 个性化（2026-09-25 加的）———
    @State private var showStyleEditor = false
    @State private var styleDraft = ""
    @State private var libraryPick: PhotosPickerItem?
    @State private var note: String?

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

            // ——— 个性化（用户要求：她发什么 / 配图 / 时段 / 外观）———
            personalization

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
        // 和别处的入口保持一致：朋友圈是**整页**，不是弹窗
        .fullScreenCover(isPresented: $showMoments) {
            MomentsView()
        }
    }

    // MARK: - 个性化（2026-09-25 用户要求）

    private var personalization: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("她发什么")

            Button {
                styleDraft = settings.momentStylePrompt
                showStyleEditor = true
            } label: {
                rowShell(
                    icon: "text.quote",
                    title: "她的朋友圈风格",
                    subtitle: settings.momentStylePrompt.isEmpty
                        ? "还没写 —— 她会自由发挥"
                        : settings.momentStylePrompt
                )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showStyleEditor) { styleEditor }

            rule
            sectionLabel("她的配图")

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $settings.momentImageMode) {
                    Text("不发图").tag("none")
                    Text("从她的图库挑").tag("library")
                }
                .pickerStyle(.segmented)

                if settings.momentImageMode == "library" {
                    Text(moments.libraryCount == 0
                         ? "图库还是空的 —— 先往下放几张图，她才有得挑。"
                         : "图库里 \(moments.libraryCount) 张，她发动态时随机挑一张。")
                        .font(.aevis(11.5))
                        .foregroundStyle(moments.libraryCount == 0 ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $libraryPick, matching: .images) {
                            Label("往图库加图", systemImage: "photo.badge.plus")
                                .font(.aevis(13.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(settings.accentColor)

                        Spacer(minLength: 8)

                        if moments.libraryCount > 0 {
                            Button("清空图库", role: .destructive) {
                                moments.clearLibrary()
                                note = "图库清空了。"
                            }
                            .font(.aevis(13.5))
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("我们没法凭空给她生成照片（那要接图像模型、要花钱）。与其假装能，"
                         + "不如让她从你给的图里挑。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .onChange(of: libraryPick) { _, item in
                guard let item else { return }
                loadLibraryImage(item)
            }

            rule
            sectionLabel("她什么时候发")

            VStack(alignment: .leading, spacing: 12) {
                weightRow("早 5–11", value: $settings.momentMorningWeight)
                weightRow("午 11–17", value: $settings.momentNoonWeight)
                weightRow("晚 17–22", value: $settings.momentEveningWeight)
                weightRow("深夜 22–5", value: $settings.momentNightWeight)

                Text("拉高 = 这个时段她更勤快；拉到 0 = 这个时段不发。四个都一样就等于不限制。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule
            sectionLabel("朋友圈长什么样")

            VStack(alignment: .leading, spacing: 12) {
                Picker("字号", selection: $settings.momentFontScale) {
                    Text("小").tag(0.9)
                    Text("标准").tag(1.0)
                    Text("大").tag(1.15)
                }
                .pickerStyle(.segmented)

                Picker("疏密", selection: $settings.momentDensityIndex) {
                    Text("紧凑").tag(0)
                    Text("标准").tag(1)
                    Text("宽松").tag(2)
                }
                .pickerStyle(.segmented)

                Picker("时间", selection: $settings.momentTimeStyle) {
                    Text("几分钟前").tag("relative")
                    Text("几点几分").tag("clock")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("卡片圆角")
                        .font(.aevis(13.5))
                    Spacer(minLength: 8)
                    Text("\(Int(settings.momentCorner))")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.momentCorner, in: 0...28, step: 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if let note {
                Text(note)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 11)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private func rowShell(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.aevis(15, weight: .medium))
                .foregroundStyle(settings.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.aevis(15.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.aevis(13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /// 时段权重一行。0 是特殊值（= 这个时段不发），所以显示成「不发」而不是「0」。
    private func weightRow(_ name: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.aevis(13.5))
                Spacer(minLength: 8)
                Text(value.wrappedValue == 0 ? "不发" : "\(value.wrappedValue)")
                    .font(.aevis(12.5))
                    .foregroundStyle(value.wrappedValue == 0 ? Color.orange : Color.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0.rounded()) }
                ),
                in: 0...100,
                step: 10
            )
        }
    }

    private var styleEditor: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("写一段她平时发朋友圈的样子。比如：\n"
                     + "「爱发吃的和猫，语气懒懒的，偶尔抱怨加班，很少发长句。」")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $styleDraft)
                    .font(.aevis(15))
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(
                        Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                Text("留空 = 不干预，她自己发挥。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("她的朋友圈风格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { showStyleEditor = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("存") {
                        settings.momentStylePrompt = styleDraft
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        showStyleEditor = false
                        note = settings.momentStylePrompt.isEmpty ? "清空了，她会自由发挥。" : "记下了。"
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func loadLibraryImage(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { libraryPick = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                note = "这张图读不出来，换一张试试。"
                return
            }
            note = moments.addLibraryImage(image)
                ? "加进图库了，现在有 \(moments.libraryCount) 张。"
                : "存图失败，可能是空间不够。"
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
