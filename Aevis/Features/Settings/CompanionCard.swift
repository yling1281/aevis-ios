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
    @State private var editingGroup = false
    @State private var groupDraft = ""

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

            // ——— 系统级录屏：录整个屏幕，要的就是这个 ———

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("录整个屏幕")
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 6)
                    Text(companion.systemRunning ? "正在录" : "没在录")
                        .font(.aevis(11.5))
                        .foregroundStyle(companion.systemRunning ? Color.green : Color.secondary)
                }

                Text("开始之后，你切到微信、抖音，她照样看得到 —— 这是录整个屏幕的那条路。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                BroadcastStartButton()

                Text(ScreenCompanion.howToStart)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // 共享容器不通 = 扩展认出来的字传不回主 App。
                // 这是签名层面的问题，用户自己改不了，所以**必须明说**，
                // 不能让他对着一个不工作的开关猜。
                if let problem = companion.extensionProblem {
                    Text(problem)
                        .font(.aevis(11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— App 内抓帧：兜底，只看得到 Aevis 自己 ———

            toggleRow(
                "只看 Aevis 自己",
                subtitle: "不用装扩展的兜底办法，但切到别的 App 她就看不到了。",
                isOn: Binding(
                    get: { companion.inAppActive || settings.companionEnabled },
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

            if settings.companionEnabled || companion.inAppActive {
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
                    Text("越勤越费电。")
                        .font(.aevis(11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            rule

            // ——— 两条通道合起来的进度 ———

            VStack(alignment: .leading, spacing: 7) {
                // 到底在不在工作 —— 光看开关判断不出来，把两条通道分别摊开
                Text(companion.diagnostics)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(ScreenCompanion.ocrLimit)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = companion.errorText {
                    Text(error)
                        .font(.aevis(11.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

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

            rule

            // 共享容器不通时的**自救口子**。
            // 重签之后那个组 id 可能不在我们手里，自动挑只能看到本进程的权限清单 ——
            // 用户要是能从签工具里看到真正生效的组名，填进来就能立刻救活录屏。
            entry(
                symbol: "square.stack.3d.up",
                title: "应用组",
                detail: ScreenShareStore.isUsable
                    ? ScreenShareStore.appGroupID
                    : "容器不通 · 点这里手动填一个（现在自动挑的是 \(ScreenShareStore.appGroupID)）"
            ) {
                groupDraft = ScreenShareStore.appGroupID
                editingGroup = true
            }
        }
        .aevisGlass(cornerRadius: 20)
        // 扩展在**另一个进程**里写「我录到哪了」，只能主动去读。
        // 轮询已经在根视图（`MainTabView`）里全程跑着，这里进来补读一次就够 ——
        // 千万不能在这里 `stopPolling`，那会把全局的轮询一起停掉。
        .onAppear { companion.refreshFromExtension() }
        .alert("应用组", isPresented: $editingGroup) {
            TextField("group.xxx", text: $groupDraft)
            Button("保存") {
                UserDefaults.standard.set(
                    groupDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: ScreenShareStore.manualKey
                )
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("留空就是自动挑。填上之后主 App 和录屏扩展都会用它 —— 改完要重新开一次录屏才生效。")
        }
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
