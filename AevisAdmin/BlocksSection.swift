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
            AdminFold("被封的账号", key: "section.blocks.users", count: store.blockedUsers.count) {
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
            }

            AdminFold("被封的设备", key: "section.blocks.devices",
                      count: store.blockedDevices.count) {
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
            }

            // 封禁记录（2026-09-28）：**含已解封的**。
            // 「自动封」是后端判出来的（同账号 24h 跨了 3 个网络），
            // 这里要把跨了哪几个 IP 摆出来 —— 误封申诉就靠这个判断。
            AdminFold("封禁记录", key: "section.blocks.events",
                      count: store.banEvents.count) {
                if store.banEvents.isEmpty {
                    AdminCard { AdminEmpty(text: "还没有封禁记录。") }
                } else {
                    AdminCard {
                        ForEach(Array(store.banEvents.enumerated()),
                                id: \.element.stableID) { index, ev in
                            AdminCardRow(showsDivider: index > 0) {
                                AdminLine(
                                    title: ev.email ?? "—",
                                    subtitle: (ev.isAuto ? "自动封" : "人工封")
                                        + ((ev.ips?.isEmpty == false) ? " · 跨 " + ev.ips! : "")
                                        + (ev.notified == false ? "（还没播报）" : ""),
                                    detail: AdminFormat.when(ev.at)
                                        + ((ev.reason?.isEmpty == false) ? "\n" + ev.reason! : "")
                                        + ((ev.deviceId?.isEmpty == false)
                                           ? "\n设备 " + ev.deviceId! : "")
                                )
                            } trailing: {
                                AdminMiniButton(title: "解封", tint: AdminSkin.brand) {
                                    Task { await store.blockUser(ev.email ?? "", blocked: false) }
                                }
                            }
                        }
                    }
                    AdminNote(text: "「自动封」是后端判出来的：同一个账号 24 小时内跨了 3 个"
                             + "不同网络（家里 WiFi + 出门 4G 是正常的两个，第 3 个说明在共享）。"
                             + "误封就点解封 —— 解封之后这个账号不会再被自动封。")
                }
            }

            AdminFold("手动封一台机器", key: "section.blocks.manual") {
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
            }

            AdminNote(text: "设备码在 App 的「设置 → 关于」里，用户也能自己看到并报给你。"
                     + "封设备不会动他的账号 —— 等他换台机器还能正常用。")
        }
    }
}
