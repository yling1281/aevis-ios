import SwiftUI

/// 站内信（2026-11-01）：通知 + 可领取的福利积分。
///
/// 数据源在 `InboxStore`（`/v1/inbox/*`，X-Account 标识用户）。
/// 这一页只负责画：进来自动标已读、个别福利点「领取」当场入账。
struct InboxView: View {
    @ObservedObject private var store = InboxStore.shared
    @State private var toast: String?

    var body: some View {
        Group {
            if store.loading && store.rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text("加载中…").font(.aevis(13)).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if store.rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.aevis(30))
                        .foregroundStyle(.tertiary)
                    Text("还没有站内信").font(.aevis(13.5)).foregroundStyle(.secondary)
                    Text("有通知和福利会出现在这里")
                        .font(.aevis(12)).foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.rows) { m in
                            InboxRow(item: m) { msg in
                                toast = msg
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("站内信")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.aevis(13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 28)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .task {
            await store.refresh()
            // 打开就算看过了 —— 用户要的是「点进来红点就消」，
            // 而不是一条条去点「已读」。
            await store.markAllRead()
        }
        .refreshable { await store.refresh() }
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let onToast: (String) -> Void

    @State private var claiming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if item.isWelfare {
                    Image(systemName: "gift.fill")
                        .font(.aevis(13))
                        .foregroundStyle(AppSettings.shared.accentColor)
                }
                Text(item.title)
                    .font(.aevis(15, weight: .medium))
                Spacer(minLength: 8)
                if !item.read && !item.claimed {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
            }

            if !item.body.isEmpty {
                Text(item.body)
                    .font(.aevis(13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text(item.createdAt)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)

                if item.isWelfare {
                    if item.claimed {
                        Label("已领取 \(item.points) 积分", systemImage: "checkmark.circle.fill")
                            .font(.aevis(12.5))
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            Task { await claim() }
                        } label: {
                            if claiming {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("领取 \(item.points) 积分")
                                    .font(.aevis(12.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(claiming)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func claim() async {
        claiming = true
        defer { claiming = false }
        let (ok, msg, balance) = await InboxStore.shared.claim(item.id)
        if !ok { onToast(msg); return }
        if let b = balance {
            onToast("已领取 \(item.points) 积分，现在共 \(b) 积分")
        } else {
            onToast("已领取 \(item.points) 积分")
        }
    }
}
