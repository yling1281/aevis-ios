import SwiftUI

/// 「陪伴」设置卡片：一起听、录屏陪伴、实时通话。
///
/// 这三件事放一起，因为它们都是「她陪着你」的不同形态。
struct CompanionCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var together = ListenTogetherService.shared
    @ObservedObject private var companion = ScreenCompanion.shared
    @ObservedObject private var player = MusicPlayer.shared

    @State private var showTogether = false
    @State private var showCall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("陪伴")

            // ——— 一起听 ———

            entry(
                symbol: "music.note.list",
                title: "一起听",
                detail: together.active
                    ? "进行中 · \(together.currentTrackTitle)"
                    : (player.current?.display ?? "歌在这台手机上放，她跟着一起听")
            ) {
                showTogether = true
            }

            rule

            // ——— 实时通话 ———

            entry(
                symbol: "phone.arrow.up.right",
                title: "实时通话",
                detail: "你说话，她听；她回话，用语音念出来"
            ) {
                showCall = true
            }

            rule

            // ——— 录屏陪伴 ———

            toggleRow(
                "录屏陪伴",
                subtitle: "她看你的屏幕 —— 画面不出手机，只在本机认文字",
                isOn: Binding(
                    get: { companion.active || settings.companionEnabled },
                    set: { value in
                        settings.companionEnabled = value
                        if value {
                            companion.start()
                            if companion.errorText != nil {
                                settings.companionEnabled = false
                            }
                        } else {
                            companion.stop()
                        }
                    }
                )
            )

            if settings.companionEnabled || companion.active {
                rule

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("每隔多少秒看一眼")
                            .font(.aevis(14))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(Int(companion.interval)) 秒")
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $companion.interval, in: 5...60, step: 5)
                    Text("越勤越费电。她看到的是屏幕上的文字，所以图片和视频里的内容她看不到。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if let error = companion.errorText {
                    rule
                    Text(error)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                }

                if !companion.lastSeen.isEmpty {
                    rule
                    VStack(alignment: .leading, spacing: 5) {
                        Text("她最近看到的")
                            .font(.aevis(12))
                            .foregroundStyle(.secondary)
                        Text(companion.lastSeen)
                            .font(.aevis(12.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .aevisGlass(cornerRadius: 20)
        .sheet(isPresented: $showTogether) {
            TogetherView()
        }
        .fullScreenCover(isPresented: $showCall) {
            CallView()
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

    private func entry(
        symbol: String,
        title text: String,
        detail: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.aevis(15, weight: .medium))
                    .foregroundStyle(AppSettings.shared.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(text)
                        .font(.aevis(15.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.aevis(12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
