import SwiftUI

/// 设置 /「我的」（2026-11-22 视觉重做）。
/// 与安卓 120/126/133 的口径一致：主题三档、字号三档、消息弹窗独立开关。
/// 视觉：个人头部卡 + 三张设置卡 + 云端备份卡 + 独立退出卡。
/// @AppStorage 键名（themeMode/msgSize/msgBanner）保持不变。
struct SettingsView: View {
    @EnvironmentObject private var session: Session

    /// 云端备份状态（Core/CloudBackup.swift 由另一位 worker 提供：
    /// `CloudBackup.shared` + `@Published var lastSyncText: String`）
    @ObservedObject private var backup = CloudBackup.shared

    @AppStorage("themeMode") private var themeMode = 0   // 0 跟随系统 / 1 浅色 / 2 深色
    @AppStorage("msgSize") private var msgSize = 1
    @AppStorage("msgBanner") private var msgBanner = true

    /// 背景（第 3 轮）：预设索引与 AppBackground.Preset 的 rawValue 对齐；模糊半径 pt。
    @AppStorage("aevisBgStyle") private var bgStyle = 0
    @AppStorage("aevisBgBlur") private var bgBlur = 0.0

    /// 4 个背景预设的展示信息（顺序 / rawValue 必须与 AppBackground.Preset 一致）。
    private struct BgPreset: Identifiable {
        let id: Int
        let name: String
        let colors: [Color]
    }
    private let bgPresets: [BgPreset] = [
        BgPreset(id: 0, name: "奶油", colors: [Color.hex(0xFFF8EC), Color.hex(0xFFF1DC)]),
        BgPreset(id: 1, name: "柔紫", colors: [Color.hex(0xF3EEFF), Color.hex(0xE7DEFF)]),
        BgPreset(id: 2, name: "海盐", colors: [Color.hex(0xEAF4F4), Color.hex(0xDCEDEF)]),
        BgPreset(id: 3, name: "深空", colors: [Color.hex(0xD9DCE6), Color.hex(0xC2C7D4)])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AE.groupGap + 4) {
                    profileHeader

                    settingsCard(title: "外观", icon: "paintbrush.fill") {
                        Picker("主题", selection: $themeMode) {
                            Text("跟随系统").tag(0)
                            Text("浅色").tag(1)
                            Text("深色").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Text("跟随系统会适配设备的深浅模式。")
                            .font(.system(size: 11))
                            .foregroundStyle(AE.textSecondary)
                    }

                    settingsCard(title: "背景", icon: "photo.fill") {
                        // 4 预设缩略图：点选即写 aevisBgStyle，AppBackground 立即生效
                        HStack(spacing: 10) {
                            ForEach(bgPresets) { p in
                                Button { withAnimation { bgStyle = p.id } } label: {
                                    VStack(spacing: 5) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(LinearGradient(
                                                    colors: p.colors,
                                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                                ))
                                                .frame(height: 46)
                                            if bgStyle == p.id {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .stroke(AE.accent, lineWidth: 2.5)
                                                    .frame(height: 46)
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 16, weight: .bold))
                                                    .foregroundStyle(AE.accent)
                                            }
                                        }
                                        Text(p.name)
                                            .font(.system(size: 11))
                                            .foregroundStyle(bgStyle == p.id ? AE.accent : AE.textSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Divider().opacity(0.4)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("背景模糊").font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                                Spacer()
                                Text("\(Int(bgBlur)) pt").font(.system(size: 11)).foregroundStyle(AE.textSecondary)
                            }
                            Slider(value: $bgBlur, in: 0...12, step: 1)
                                .tint(AE.accent)
                        }
                        Text("选中的背景和模糊度会立即应用到主页与商城。")
                            .font(.system(size: 11))
                            .foregroundStyle(AE.textSecondary)
                    }

                    settingsCard(title: "消息大小", icon: "textformat.size") {
                        Picker("字号", selection: $msgSize) {
                            Text("小").tag(0)
                            Text("标准").tag(1)
                            Text("大").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }

                    settingsCard(title: "通知", icon: "bell.fill") {
                        Toggle("新消息弹窗", isOn: $msgBanner)
                            .tint(AE.accent)
                    }

                    settingsCard(title: "云端备份", icon: "icloud.fill") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AE.accent)
                            Text(backup.lastSyncText.isEmpty ? "尚未同步" : backup.lastSyncText)
                                .font(.system(size: 12))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }

                    logoutCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .background(Color.paper)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(
                themeMode == 1 ? .light : (themeMode == 2 ? .dark : nil)
            )
        }
    }

    // MARK: - 组件

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(
                    LinearGradient(
                        colors: [AE.accentLift, AE.accentDeep],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                ).frame(width: 68, height: 68)
                Image(systemName: "dog.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: AE.accent.opacity(0.28), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 5) {
                Text("Aevis")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("把想说的话，留给懂你的人。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.hex(0x36415E), AE.accentDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius + 4, style: .continuous))
        .shadow(color: AE.shadowColor, radius: 10, y: 4)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AE.accent)
                Text(title)
                    .font(.system(size: AE.sectionTitle, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // 磨砂玻璃卡（.regular 更实一点，保证 segmented/toggle 的可读性）；文字保持语义色
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    private var logoutCard: some View {
        Button {
            session.signOut()
        } label: {
            Text("退出登录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(AE.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
        .padding(16)
        .frame(maxWidth: .infinity)
        // 磨砂玻璃卡；内部「退出登录」按钮背景 AE.accentSoft 保持实心，保留按钮对比度
        .glassCard(cornerRadius: AE.cardRadius, material: .regular)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }
}
