import SwiftUI

/// 设置 /「我的」（2026-11-22 视觉重做，照用户给的「忆伴」设置页参考图）。
///
/// 只放**真实生效**的功能（用户要求：没实现的先不要放按钮）：
/// - 品牌卡（自家狗 logo + 标语，点击进账号中心）
/// - 外观：跟随系统 / 浅色 / 深色 —— 写 `themeMode`，由 `AevisApp` 根视图统一读取生效
/// - 配置：服务器状态（真实探测四条线路 + `/v1/models/status`）、主题配置（背景图/位置/模糊）
/// - 消息大小：小 / 标准 / 大（`msgSize`，ChatView 里 `AE.chatFont(msgSize)` 在用）
/// - 数据：云端同步状态 + 手动「从云端恢复聊天记录」（`CloudBackup.restoreNow`）
/// - 退出登录
///
/// 存储键保持不变：themeMode / msgSize / aevisBgStyle / aevisBgBlur / aevisBgImagePath。
/// 卡片统一磨砂玻璃 + 20 圆角，层次靠材质和留白，不靠重边框。
struct SettingsView: View {
    @EnvironmentObject private var session: Session

    /// 云端备份状态（`CloudBackup.shared` 的 lastSyncText / restoreNow 都是真实实现）
    @ObservedObject private var backup = CloudBackup.shared

    @AppStorage("themeMode") private var themeMode = 0   // 0 跟随系统 / 1 浅色 / 2 深色
    @AppStorage("msgSize") private var msgSize = 1

    /// 背景（第 3 轮）：预设索引与 AppBackground.Preset 的 rawValue 对齐。
    /// 详细调节都移到「主题配置」页，这里只读出来显示当前用的是哪套。
    @AppStorage("aevisBgStyle") private var bgStyle = 0
    @AppStorage("aevisBgImagePath") private var bgImagePath = ""

    /// 账号中心（2026-11-22 新增）：点顶部品牌卡打开。
    @State private var showAccount = false

    /// 手动云端恢复的进行中 / 结果提示。
    @State private var restoring = false
    @State private var restoreMessage = ""
    @State private var showRestoreAlert = false

    /// 4 个背景预设的名字（顺序 / rawValue 必须与 AppBackground.Preset 一致）。
    private let bgNames = ["奶油", "柔紫", "海盐", "深空"]

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    brandCard

                    sectionCard(title: "外观", icon: "paintbrush.fill") {
                        SettingsSegment(items: ["跟随系统", "浅色", "深色"], index: $themeMode)
                        hint("跟随系统会适配设备的深浅模式。")
                    }

                    sectionCard(title: "配置", icon: "slider.horizontal.3") {
                        navRow(icon: "server.rack", title: "服务器状态", value: currentLineText) {
                            ServerStatusView()
                        }
                        innerDivider
                        navRow(icon: "paintbrush", title: "主题配置", value: themeText) {
                            ThemeSettingsView()
                        }
                        hint("服务器状态会实测各条线路延迟，并展示 DeepSeek / 双子星 / Claude 的模型可用率；主题配置可换相册背景图、调位置和模糊。")
                    }

                    sectionCard(title: "消息大小", icon: "textformat.size") {
                        SettingsSegment(items: ["小", "标准", "大"], index: $msgSize)
                    }

                    sectionCard(title: "数据", icon: "icloud.fill") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AE.accent)
                            Text(backup.lastSyncText.isEmpty ? "尚未同步" : backup.lastSyncText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(AE.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        innerDivider
                        restoreRow
                        hint("恢复只补本机缺少的记录，不会删除或覆盖本地聊天。")
                    }

                    logoutCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)
                // 原生 TabView 已把底栏安全区让出来，这里只留一点呼吸感
                .padding(.bottom, 40)
            }
            .background(Color.paper)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAccount) {
                AccountCenterView()
                    .environmentObject(session)
            }
            .alert("从云端恢复", isPresented: $showRestoreAlert) {
                Button("好", role: .cancel) { }
            } message: {
                Text(restoreMessage)
            }
        }
    }

    // MARK: - 品牌卡（点击进账号中心）

    private var brandCard: some View {
        Button { showAccount = true } label: {
            HStack(spacing: 14) {
                AevisMascot(size: 54)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Aevis")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("把想说的话，留给懂你的人。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.white.opacity(0.72))
                }

                Spacer(minLength: 0)

                HStack(spacing: 4) {
                    Text("账号中心")
                        .font(.system(size: 11.5, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.hex(0x3B4768), AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius + 4, style: .continuous))
            .shadow(color: AE.accentDeep.opacity(0.22), radius: 12, y: 6)
        }
        .buttonStyle(AevisPressStyle(scale: 0.985))
    }

    // MARK: - 组件

    /// 分组卡：标题行（图标 + 标题）+ 内容，整卡磨砂玻璃。
    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String, icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
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
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    /// 设置行 → 子页面。右侧显示当前状态，样式与其它设置行一致（磨砂卡内一行）。
    private func navRow<Destination: View>(
        icon: String, title: String, value: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .font(.system(size: 14.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(AE.textSecondary.opacity(0.45))
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 当前生效线路（自动回落时显示自动选中的那条）。真实值取自 APIClient，不写死。
    private var currentLineText: String {
        APIClient.activeLine.name
    }

    /// 当前背景：有自定义图显示「自定义」，否则显示预设名（详细调节在主题配置页）
    private var themeText: String {
        if !bgImagePath.isEmpty { return "自定义" }
        let idx = min(max(bgStyle, 0), bgNames.count - 1)
        return bgNames[idx]
    }

    /// 真实入口：从云端把已备份的聊天记录合并回本机（只补本地没有的）。
    /// 未登录（拿不到 token）时置灰禁用。
    private var restoreRow: some View {
        let available = !(session.token ?? "").isEmpty
        return Button {
            restoreFromCloud()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                Text(restoring ? "正在从云端恢复…" : "从云端恢复聊天记录")
                    .font(.system(size: 14.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 6)
                if restoring {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available || restoring)
        .opacity(available ? 1 : 0.4)
    }

    private func restoreFromCloud() {
        guard let token = session.token, !token.isEmpty, !restoring else { return }
        restoring = true
        Task {
            await CloudBackup.shared.restoreNow(token: token, email: session.email)
            await MainActor.run {
                restoring = false
                restoreMessage = backup.lastSyncText.isEmpty ? "已完成云端恢复。" : backup.lastSyncText
                showRestoreAlert = true
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var innerDivider: some View {
        Rectangle()
            .fill(AE.textSecondary.opacity(0.14))
            .frame(height: 0.7)
    }

    private var logoutCard: some View {
        Button {
            session.signOut()
        } label: {
            Text("退出登录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(AE.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
        .padding(14)
        .frame(maxWidth: .infinity)
        // 磨砂玻璃卡；内部「退出登录」按钮背景 AE.accentSoft 保持实心，保留按钮对比度
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }
}

// MARK: - 三段选择器（选中项白底加粗，照参考图）

/// 私有组件：只在设置页用。选中项是白色圆角块 + 阴影 + semibold，
/// 未选中是次要文字；整条轨道用 accentSoft 淡底。
private struct SettingsSegment: View {
    let items: [String]
    @Binding var index: Int

    private var selectedFill: Color {
        Color.adaptive(dark: Color.hex(0x3C4256), light: .white)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = index == i
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { index = i }
                } label: {
                    Text(items[i])
                        .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? AE.textPrimary : AE.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selectedFill)
                                    .shadow(color: Color.black.opacity(0.07), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AE.accentSoft.opacity(0.85))
        )
    }
}
