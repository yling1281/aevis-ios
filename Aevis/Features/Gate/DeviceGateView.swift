import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 授权门禁页 —— **这台设备没授权的时候，这是进 App 唯一能看到的一屏。**
///
/// ## 用户定的口径（2026-09-25）
/// 「打开 APP 就提示没有授权，然后就展示设备码和没有授权的那个界面」
/// 「填设备码之后就自动通过，就是一个账号一个设备码」。
///
/// 所以这一屏只干三件事：**说清楚没授权**、**把设备码摆出来**、
/// **把人送去网页**（登录 + 填码都在那个页面上做）。
/// 用户在网页那边点完「绑定这台设备」，这边**自己就会发现**并放行 ——
/// 不需要他再回来点任何东西（当然也给一个手动检查的按钮，
/// 因为"等它自己发现"这件事用户是看不见的）。
struct DeviceGateView: View {

    @ObservedObject private var gate = DeviceGate.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var account = AccountService.shared

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                badge
                    .padding(.top, 54)

                Text("这台设备还没有授权")
                    .font(.aevis(21, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                Text("登录你的账号，把这台设备的设备码填进去。\n绑上就算授权，这个页面会自己进去。")
                    .font(.aevis(13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 6)

                codeCard
                    .padding(.top, 24)

                primaryButton
                    .padding(.top, 18)

                checkButton
                    .padding(.top, 6)

                statusBlock
                    .padding(.top, 16)

                footnote
                    .padding(.top, 26)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        // 轮询：用户在网页上点完绑定就会切回 App，
        // 那时候这一圈循环刚好把新状态拿到 —— 他不用做任何事。
        .task { await waitForGrant() }
        .onChange(of: scenePhase) { _, phase in
            // 从浏览器切回来，立刻查一次，别让他干等 5 秒
            guard phase == .active else { return }
            Task { await gate.refresh() }
        }
    }

    // MARK: - 上半部分

    private var badge: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.06))
                .frame(width: 86, height: 86)
            // ⚠️ 图标用系统字号是**故意**的（R7 那条规则专门放过了 SF Symbol）：
            // 图标不该跟着用户选的字体变。
            Image(systemName: "lock.shield")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(settings.accentColor)
        }
    }

    // MARK: - 设备码

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备码")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 7)

            rule

            HStack(spacing: 10) {
                Text(DeviceIdentity.pretty)
                    // 等宽 + 跟着字号设置走（`aevisMono`）。抄码的时候少看错一位。
                    .font(.aevisMono(18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Spacer(minLength: 8)

                Button {
                    copy()
                } label: {
                    Text(copied ? "已复制" : "复制")
                        .font(.aevis(13.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(settings.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            rule

            Text("在网页上要填的就是这一串。少打一个短横也没事。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 按钮

    private var primaryButton: some View {
        Button {
            if let url = DeviceIdentity.bindPage { openURL(url) }
        } label: {
            Text("去网页登录并绑定")
                .font(.aevis(15.5, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var checkButton: some View {
        Button {
            Task { await gate.refresh() }
        } label: {
            Text(gate.checking ? "检查中…" : "我已经绑好了，检查一下")
                .font(.aevis(14))
                .foregroundStyle(settings.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .disabled(gate.checking)
    }

    // MARK: - 状态

    private var statusBlock: some View {
        VStack(spacing: 6) {
            if gate.checking && !gate.reachedServer {
                ProgressView()
                    .controlSize(.small)
            }

            Text(gate.statusLine)
                .font(.aevis(12.5))
                // ⚠️ 三元的两边**必须同类型**：`.secondary` 是 HierarchicalShapeStyle、
                // `.orange` 是 Color —— 写成 `.secondary : .orange` 编译器会报
                // "member 'orange' in 'HierarchicalShapeStyle' produces result of type 'Color'"。
                // build-54 就挂在它上。都写成 `Color.` 才是同一个类型。
                .foregroundStyle(gate.problem == nil ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // 他之前要是登录过，就顺带说一句"你登录的是哪个号" ——
            // 网页上填设备码必须登录，先说清楚能省掉一轮来回。
            if account.isSignedIn, let profile = account.profile, !profile.username.isEmpty {
                Text("这台手机上登录过：\(profile.username)")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
    }

    private var footnote: some View {
        Text("一个账号只能绑一台设备。要换机，在同一个网页上申请（一辈子只能申请一次）。\n"
             + "授权会记在这台手机上 —— 以后再打开就不需要联网了。")
            .font(.aevis(11.5))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 动作

    /// 每 5 秒查一次，直到查到授权为止。
    ///
    /// 用户去浏览器填码时 App 会退到后台、这个循环跟着停 ——
    /// 所以回来那次靠 `scenePhase` 补，两条路缺一不可。
    private func waitForGrant() async {
        while !Task.isCancelled {
            await gate.refresh()
            if gate.authorized { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func copy() {
        #if canImport(UIKit)
        UIPasteboard.general.string = DeviceIdentity.pretty
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            copied = false
        }
        #endif
    }

    // MARK: - 零件

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}
