import SwiftUI

/// 「云同步」卡片（2026-10-31）。
///
/// 用户原话：「都说了所有东西上传到云端，聊天记录所有东西同步到云端，多端同步知道吗？」
///
/// 这张卡只做三件事：告诉用户**现在同步到哪一步**、能不能关、以及一个"我手动试一下"。
/// 真正干活的是 `ChatSyncService`。
struct SyncCard: View {
    @ObservedObject private var sync = ChatSyncService.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.aevis(13, weight: .medium))
                Text("云同步")
                    .font(.aevis(15, weight: .semibold))
                Spacer(minLength: 0)
                Text(sync.statusLine)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
            }

            Text("聊天记录会跟着账号走。换台手机登录同一个账号，记录会自己回来。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $sync.autoSyncEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动同步")
                        .font(.aevis(14))
                    Text("发一条就推一条；回到 App 时拉一次")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .tint(settings.accentColor)

            if !sync.canSync {
                Text("还没登录账号 —— 登录之后才会同步。")
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = sync.lastError {
                Text(error)
                    .font(.aevis(12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await sync.sync(force: true) }
            } label: {
                HStack(spacing: 6) {
                    if sync.syncing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.aevis(12.5, weight: .medium))
                    }
                    Text(sync.syncing ? "正在同步…" : "立即同步")
                        .font(.aevis(13.5, weight: .medium))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .aevisGlass(cornerRadius: 13)
            }
            .buttonStyle(.plain)
            .disabled(sync.syncing || !sync.canSync)

            if sync.pushedCount > 0 || sync.pulledCount > 0 {
                Text("本次已推 \(sync.pushedCount) 条、拉回 \(sync.pulledCount) 条")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aevisGlass(cornerRadius: 20)
    }
}
