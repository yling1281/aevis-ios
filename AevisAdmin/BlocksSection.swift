import SwiftUI
import UIKit

/// 封禁：谁被封了、哪台机器被封了，以及手动封一台机器。
///
/// 封设备是**按设备码**记的，跟账号解耦 —— 他删号重注册、换个邮箱再来，
/// 只要还是这台机器就绑不上账号。（挡不挡得住刷机，取决于设备码够不够硬。）
struct BlocksSection: View {
    @EnvironmentObject private var store: AdminStore

    @State private var deviceInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "被封的账号（\(store.blockedUsers.count)）")
            if store.blockedUsers.isEmpty {
                AdminCard { AdminEmpty(text: "没有封过账号。") }
            } else {
                AdminCard {
                    ForEach(Array(store.blockedUsers.enumerated()), id: \.element.id) { index, user in
                        AdminCardRow(showsDivider: index > 0) {
                            AdminLine(
                                title: user.email ?? "—",
                                subtitle: (user.blockedReason?.isEmpty == false
                                           ? user.blockedReason! : "（没写原因）"),
                                detail: "封于 \(AdminFormat.when(user.blockedAt))"
                            )
                        } trailing: {
                            AdminMiniButton(title: "解封", tint: AdminSkin.brand) {
                                Task { await store.blockUser(user.email ?? "", blocked: false) }
                            }
                        }
                    }
                }
            }

            AdminSectionTitle(text: "被封的设备（\(store.blockedDevices.count)）")
            if store.blockedDevices.isEmpty {
                AdminCard { AdminEmpty(text: "没有封过设备。") }
            } else {
                AdminCard {
                    ForEach(Array(store.blockedDevices.enumerated()), id: \.element.id) { index, device in
                        AdminCardRow(showsDivider: index > 0) {
                            AdminLine(
                                title: device.deviceId ?? "—",
                                subtitle: (device.reason?.isEmpty == false
                                           ? device.reason! : "（没写原因）"),
                                detail: "封于 \(AdminFormat.when(device.blockedAt))"
                            )
                        } trailing: {
                            AdminMiniButton(title: "解封", tint: AdminSkin.brand) {
                                Task { await store.blockDevice(device.deviceId ?? "", blocked: false) }
                            }
                        }
                    }
                }
            }

            AdminSectionTitle(text: "手动封一台机器")
            AdminCard {
                VStack(alignment: .leading, spacing: 11) {
                    TextField("设备码，比如 AEVIS-CA69-2F36-4948", text: $deviceInput)
                        .font(.system(size: 13.5, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    HStack(spacing: 8) {
                        AdminMiniButton(title: "封掉这台", tint: AdminSkin.danger, filled: true) {
                            let code = deviceInput.trimmingCharacters(in: .whitespaces)
                            guard !code.isEmpty else { return }
                            Task {
                                await store.blockDevice(code, blocked: true)
                                deviceInput = ""
                            }
                        }
                        AdminMiniButton(title: "解封这台", tint: AdminSkin.brand) {
                            let code = deviceInput.trimmingCharacters(in: .whitespaces)
                            guard !code.isEmpty else { return }
                            Task {
                                await store.blockDevice(code, blocked: false)
                                deviceInput = ""
                            }
                        }
                    }
                }
                .padding(14)
            }
            AdminNote(text: "设备码在 App 的「设置 → 关于」里，用户也能自己看到并报给你。"
                     + "封设备不会动他的账号 —— 等他换台机器还能正常用。")
        }
    }
}
