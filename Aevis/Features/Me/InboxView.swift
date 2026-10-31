import SwiftUI

/// 站内信（2026-11-01）：通知 + 可领取的福利积分。
/// 数据源 `/v1/inbox/*`（X-Account 标识用户，跟云同步同一套身份）。
struct InboxView: View {
    @State private var rows: [InboxItem] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text("加载中…").font(.aevis(13)).foregroundStyle(.secondary)
                    Spacer()
                }
            } else if rows.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.aevis(30))
                        .foregroundStyle(.tertiary)
                    Text("还没有站内信").font(.aevis(13.5)).foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(rows) { m in
                            InboxRow(item: m) { Task { await load() } }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
        .navigationTitle("站内信")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        loading = rows.isEmpty
        defer { loading = false }
        let account = AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else { loading = false; return }
        var req = URLRequest(url: URL(string: AevisHosts.accountBase + "/v1/inbox/list")!)
        req.setValue(account, forHTTPHeaderField: "X-Account")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let items = d["rows"] as? [[String: Any]] else { return }
        rows = items.map(InboxItem.init(dict:))
    }
}

private struct InboxItem: Identifiable {
    let id: Int
    let kind: String
    let title: String
    let body: String
    let points: Int
    let claimed: Bool
    let read: Bool
    let createdAt: String

    init(dict: [String: Any]) {
        id = dict["id"] as? Int ?? 0
        kind = dict["kind"] as? String ?? "notice"
        title = dict["title"] as? String ?? ""
        body = dict["body"] as? String ?? ""
        points = dict["points"] as? Int ?? 0
        claimed = (dict["claimed"] as? Bool) ?? false
        read = (dict["read"] as? Bool) ?? false
        createdAt = dict["created_at"] as? String ?? ""
    }
}

private struct InboxRow: View {
    let item: InboxItem
    let onDone: () -> Void

    @State private var claiming = false
    @State private var claimedNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if item.kind == "welfare" {
                    Image(systemName: "gift.fill")
                        .font(.aevis(13))
                        .foregroundStyle(AppSettings.shared.accentColor)
                }
                Text(item.title)
                    .font(.aevis(15, weight: .medium))
                Spacer(minLength: 8)
                if !item.read && !claimedNow {
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

                if item.kind == "welfare" && item.points > 0 {
                    if item.claimed || claimedNow {
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
        let account = AppSettings.shared.accountEmail
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty else { return }
        var req = URLRequest(url: URL(string: AevisHosts.accountBase + "/v1/inbox/claim")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(account, forHTTPHeaderField: "X-Account")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": item.id])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["code"] as? Int) == 0 else { return }
        claimedNow = true
        onDone()
    }
}
