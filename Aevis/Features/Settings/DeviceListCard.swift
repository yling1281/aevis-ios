import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「登录设备」卡片 —— 跟微信一样：一眼看清这个账号登着几台机器，
/// 不是你的那一台，点一下就能把它踢下线。
///
/// ## 为什么值得放在设置里
/// 老板原话：「能显示你有几个设备登录了，就跟微信一样的。」
/// 账号能被几处同时用，就得让用户**看得见、管得着** ——
/// 不然换了手机、或者哪儿漏了 token，本人根本不知道有几台还登着。
///
/// ## 三条口径（后端契约，别自作主张）
/// · `device_id` / `name` 可能是**空串**（老 token 认不出设备）⇒ 显示「未知设备」；
/// · `last_seen` / `first_seen` 是 **Unix 秒**，`0` 表示**从没记录过**
///   ⇒ 显示「时间不详」，**绝不渲染成 1970 年**；
/// · `current == true` 的是**本机** ⇒ 不给「退出该设备」按钮（后端也会拒）。
struct DeviceListCard: View {

    /// 三种状态：加载中 / 出错 / 拿到数据（可能是空列表）。
    private enum Phase {
        case loading
        case failed(String)
        case loaded
    }

    @State private var phase: Phase = .loading
    @State private var devices: [AccountService.DeviceSession] = []
    /// 正在踢某台设备的档期 —— 挡住重复点。
    @State private var busy = false
    /// 点了「退出该设备」、等二次确认的那一台。
    @State private var confirmTarget: AccountService.DeviceSession?
    /// 操作结果 / 失败原因，如实说。
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("登录设备")

            header

            switch phase {
            case .loading:
                loadingRow
            case let .failed(message):
                failedRow(message)
            case .loaded:
                if devices.isEmpty {
                    emptyRow
                } else {
                    ForEach(devices) { device in
                        rule
                        deviceRow(device)
                    }
                }
            }

            if let note {
                rule
                Text(note)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
        .aevisGlass(cornerRadius: 20)
        .task { await load() }
        .alert(
            "退出这台设备？",
            isPresented: Binding(
                get: { confirmTarget != nil },
                set: { if !$0 { confirmTarget = nil } }
            )
        ) {
            Button("退出", role: .destructive) {
                if let target = confirmTarget { Task { await revoke(target) } }
            }
            Button("取消", role: .cancel) { confirmTarget = nil }
        } message: {
            Text("「\(displayName(confirmTarget))」上的登录会立刻失效，要重新登录才能用。")
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(countLine)
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                Text("这是你这个账号登着的设备。不是你的那一台，点「退出该设备」就能把它踢下线。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.aevis(14))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 一句实话：加载中就说加载中，失败就说没拿到 —— 不许编个数。
    private var countLine: String {
        switch phase {
        case .loading: return "正在查…"
        case .failed: return "没拿到设备列表"
        case .loaded: return "当前有 \(devices.count) 台设备登录"
        }
    }

    // MARK: - 三态

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在查…")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func failedRow(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await load() }
            } label: {
                Text("重试")
                    .font(.aevis(13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .aevisGlass(cornerRadius: 12)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var emptyRow: some View {
        Text("没拿到设备列表 —— 服务器没返回任何设备。点右上角的刷新再试一次。")
            .font(.aevis(12.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
    }

    // MARK: - 一台设备

    private func deviceRow(_ device: AccountService.DeviceSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: device.isCurrent ? "iphone" : "iphone.gen3")
                .font(.aevis(15))
                .foregroundStyle(AppSettings.shared.accentColor)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(device))
                        .font(.aevis(14.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if device.isCurrent { currentBadge }
                }
                Text(detail(device))
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !device.isCurrent {
                Button {
                    confirmTarget = device
                } label: {
                    Text("退出该设备")
                        .font(.aevis(12.5))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .aevisGlass(cornerRadius: 11)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var currentBadge: some View {
        Text("本机")
            .font(.aevis(10.5, weight: .medium))
            .foregroundStyle(AppSettings.shared.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(AppSettings.shared.accentColor.opacity(0.14))
            )
    }

    // MARK: - 文案

    /// 主标题：认不出设备就老实说「未知设备」，绝不把空串摆出来。
    private func displayName(_ device: AccountService.DeviceSession?) -> String {
        guard let device else { return "这台设备" }
        return device.name.isEmpty ? "未知设备" : device.name
    }

    /// 副标题：上次活跃时间 · IP。
    private func detail(_ device: AccountService.DeviceSession) -> String {
        var parts: [String] = ["上次活跃 " + lastSeenText(device.lastSeen)]
        if !device.ip.isEmpty { parts.append(device.ip) }
        return parts.joined(separator: " · ")
    }

    /// Unix 秒 → 中文时间；**0 就是「时间不详」**（不是 1970）。
    private func lastSeenText(_ stamp: Int) -> String {
        guard stamp > 0 else { return "时间不详" }
        return Self.formatter.string(from: Date(timeIntervalSince1970: TimeInterval(stamp)))
    }

    private var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 HH:mm"
        return f
    }()

    // MARK: - 动作

    @MainActor
    private func load() async {
        phase = .loading
        note = nil
        do {
            devices = try await AccountService.shared.listDevices()
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func revoke(_ device: AccountService.DeviceSession) async {
        confirmTarget = nil
        busy = true
        defer { busy = false }
        do {
            let count = try await AccountService.shared.revokeDevice(device.deviceID)
            // 把这一行就地移除 —— 不重新拉整份，免得网络抖一下就把列表打回"没拿到"。
            devices.removeAll { $0.id == device.id }
            note = count > 0
                ? "已退出「\(displayName(device))」。"
                : "服务器说这台设备已经没有可退的登录了。"
        } catch {
            note = error.localizedDescription
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
}
