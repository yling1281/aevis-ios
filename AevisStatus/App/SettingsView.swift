import SwiftUI

/// 「Aevis 状态」主界面：当前状态 + 设置。
///
/// 视觉：苹果玻璃质感（`.ultraThinMaterial`），背景**要么纯白要么纯黑**
/// （`systemBackground` 在浅色下是纯白、深色下是纯黑），**不要渐变、不要背景图**。
///
/// ⚠️ `Text` 的 markdown 陷阱（R17）：本文件里的字符串**一个加粗星号都不许有**。
struct SettingsView: View {

    @ObservedObject private var store = StatusStore.shared

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard
                    settingsCard
                }
                .padding(16)
            }
        }
    }

    // MARK: - 标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Aevis 状态")
                .font(.title2).bold()
            Text("采集手机状态并定时上报给你的 AI")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 当前状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前状态").font(.headline)

            if let snapshot = store.lastSnapshot {
                row("位置", snapshot.hasLocation ? snapshot.place : "没拿到")
                row("电量", batteryText(snapshot))
                row("设备", deviceText(snapshot))
                row("网络", networkText(snapshot))
                row("WiFi", snapshot.wifiName.isEmpty ? "没拿到" : snapshot.wifiName)
                row("步数", snapshot.hasSteps ? "\(snapshot.steps) 步" : "没拿到")
            } else {
                Text("还没采集过").foregroundStyle(.secondary).font(.subheadline)
            }

            Divider()
            uploadBlock
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var uploadBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = store.lastResult {
                Text(result.success ? "上次上报：成功" : "上次上报：失败")
                    .foregroundStyle(result.success ? .green : .red)
                Text("时间：\(Self.timeText(result.at))").foregroundStyle(.secondary)
                if !result.message.isEmpty {
                    Text("服务器：\(result.message)").foregroundStyle(.secondary)
                }
            } else {
                Text("还没上报过").foregroundStyle(.secondary)
            }
            if !store.note.isEmpty {
                Text(store.note).foregroundStyle(.secondary)
            }
            Text(store.locationStatus).foregroundStyle(.secondary)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    // MARK: - 设置

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("上报地址").font(.footnote).foregroundStyle(.secondary)
                TextField("填上报地址", text: $store.reportURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("上报密钥").font(.footnote).foregroundStyle(.secondary)
                SecureField("填上报密钥（只存在本机）", text: $store.reportKey)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("开启定时上报", isOn: $store.enabled)

            Button {
                StatusService.shared.trigger(reason: "手动", manual: true)
            } label: {
                Text(store.loading ? "正在上报" : "立刻上报一次")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.loading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - 文案

    private func batteryText(_ snapshot: StatusSnapshot) -> String {
        guard snapshot.hasBattery else { return "没拿到" }
        return snapshot.batteryCharging ? "\(snapshot.batteryLevel)% 充电中" : "\(snapshot.batteryLevel)%"
    }

    private func deviceText(_ snapshot: StatusSnapshot) -> String {
        let system = "\(snapshot.systemName) \(snapshot.systemVersion)"
        return snapshot.machine.isEmpty ? system : "\(snapshot.machine) / \(system)"
    }

    private func networkText(_ snapshot: StatusSnapshot) -> String {
        guard snapshot.hasNetwork else { return "没拿到" }
        let state = snapshot.networkOnline ? "在线" : "离线"
        return snapshot.networkKind.isEmpty ? state : "\(state) / \(networkLabel(snapshot.networkKind))"
    }

    /// 网络类型的值是服务端契约里的英文（wifi / cellular / ethernet / other），
    /// 界面上翻成中文显示。
    private func networkLabel(_ kind: String) -> String {
        switch kind {
        case "wifi": return "WiFi"
        case "cellular": return "蜂窝网络"
        case "ethernet": return "有线网络"
        case "other": return "其它"
        default: return kind
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日 HH:mm:ss"
        return formatter.string(from: date)
    }
}
