import SwiftUI
import UIKit

/// 换机申请。
///
/// 用户换手机之后会在网页上提「申请换机」——**一个账号一辈子只能提一次**，
/// 所以批准前确认一下他确实换了设备（下面把「现在绑的」和「想换成的」并排摆出来）。
/// 批准之后他的账号就绑到新的设备码上。
struct DevicesSection: View {
    @EnvironmentObject private var store: AdminStore

    private var pending: [DeviceRequest] { store.deviceRequests.filter(\.isPending) }
    private var done: [DeviceRequest] { store.deviceRequests.filter { !$0.isPending } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AdminSectionTitle(text: "待处理（\(pending.count)）")
            if pending.isEmpty {
                AdminCard { AdminEmpty(text: "没有待处理的换机申请。") }
            } else {
                ForEach(pending) { request in
                    AdminCard { requestCard(request, actionable: true) }
                }
            }

            if !done.isEmpty {
                AdminSectionTitle(text: "处理过的")
                AdminCard {
                    ForEach(Array(done.enumerated()), id: \.element.stableID) { index, request in
                        AdminCardRow(showsDivider: index > 0) {
                            AdminLine(
                                title: request.email ?? "—",
                                subtitle: "\(request.statusText)　\(AdminFormat.when(request.at))",
                                detail: "新设备 \(request.deviceId ?? "—")\n"
                                    + "原来绑的 \(request.currentDevice ?? "（没绑过）")"
                            )
                        } trailing: {
                            EmptyView()
                        }
                    }
                }
            }

            AdminNote(text: "「原设备码」是空的话，说明他注册之后一直没绑过机器 —— "
                     + "这种直接批准就行。两次设备码一样的话要留个心，问一句再批。")
        }
    }

    private func requestCard(_ request: DeviceRequest, actionable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            AdminLine(
                title: request.email ?? "—",
                subtitle: "提交于 \(AdminFormat.when(request.at))（\(AdminFormat.ago(request.at))）",
                badge: ("待处理", AdminSkin.warn)
            )

            VStack(alignment: .leading, spacing: 5) {
                devicePair("原来绑的", request.currentDevice, tint: .secondary)
                devicePair("想换成", request.deviceId, tint: AdminSkin.brand)
            }

            if actionable, let id = request.id {
                HStack(spacing: 8) {
                    AdminMiniButton(title: "拒绝", tint: AdminSkin.danger) {
                        Task { await store.approveDevice(id: id, approve: false) }
                    }
                    AdminMiniButton(title: "批准换机", tint: AdminSkin.brand, filled: true) {
                        Task { await store.approveDevice(id: id, approve: true) }
                    }
                }
            }
        }
        .padding(14)
    }

    private func devicePair(_ label: String, _ value: String?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "（没有）")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
