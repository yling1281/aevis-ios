import SwiftUI
import UIKit

/// 创作者客服 / 活动 / 邀请码（2.8 P2）。
/// 四个接口都是 team-lead 给定契约，未上线时**只显示「暂无数据」**，
/// 群链接每次进页面从 `/v1/growth/config` 热拉并落硬缓存，绝不写死 URL。
struct GrowthView: View {
    @State private var config: GrowthAPI.GrowthConfig? = nil
    @State private var activities: [GrowthAPI.GrowthActivity] = []
    @State private var inviteCode = ""
    @State private var inviteResult: GrowthAPI.InviteResult? = nil
    @State private var tip = ""
    @State private var binding = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                entryCard.staggerIn(0)
                activityCard.staggerIn(1)
                inviteCard.staggerIn(2)
                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .transition(.opacity)
                }
            }
            .padding(18)
            .padding(.bottom, 30)
        }
        .background(Color.clear)
        .navigationTitle("创作者与活动")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: - 入口（链接来自服务端）

    private var entryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷入口")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AE.textPrimary)

            entryRow(
                icon: "bubble.left.and.bubble.right.fill",
                title: "加入用户群",
                subtitle: config?.groupJoinUrl.isEmpty == false ? "点击打开群邀请" : "暂无数据",
                url: config?.groupJoinUrl
            )
            Divider().opacity(0.25)
            entryRow(
                icon: "person.crop.square.fill.and.at.rectangle",
                title: "创作者客服",
                subtitle: config?.wechatWorkUrl.isEmpty == false ? "企业微信客服" : "暂无数据",
                url: config?.wechatWorkUrl
            )
            if let activityUrl = config?.activityUrl, !activityUrl.isEmpty {
                Divider().opacity(0.25)
                entryRow(
                    icon: "gift.fill",
                    title: "活动中心",
                    subtitle: "点击查看全部活动",
                    url: activityUrl
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 12, y: 5)
    }

    private func entryRow(icon: String, title: String, subtitle: String, url: String?) -> some View {
        Button { open(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 26, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AE.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 4)
                if url != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AE.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .opacity(url == nil ? 0.6 : 1)
    }

    private func open(_ raw: String?) {
        guard let raw, !raw.isEmpty, let url = URL(string: raw) else {
            showTip("暂无数据")
            return
        }
        guard UIApplication.shared.canOpenURL(url) else {
            showTip("打不开这个链接")
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    // MARK: - 活动列表

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("进行中的活动")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AE.textPrimary)
            if activities.isEmpty {
                emptyLine("暂无数据")
            } else {
                ForEach(Array(activities.enumerated()), id: \.element.id) { pair in
                    activityRow(pair.element)
                        .staggerIn(min(pair.offset, 4))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.18)
        .shadow(color: AE.shadowColor, radius: 12, y: 5)
    }

    private func activityRow(_ a: GrowthAPI.GrowthActivity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(a.title.isEmpty ? "活动" : a.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 4)
                if a.rewardPoints > 0 {
                    Text("+\(a.rewardPoints) 墨点")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(AE.brandPurple)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(AE.brandLilac, in: Capsule())
                }
            }
            if !a.summary.isEmpty {
                Text(a.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                    .lineLimit(2)
            }
            if !a.url.isEmpty {
                Button { open(a.url) } label: {
                    Text("查看详情").font(.system(size: 11.5, weight: .medium)).foregroundStyle(AE.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AE.accentSoft.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 邀请码

    private var inviteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("邀请码")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AE.textPrimary)
            Text("绑定后奖励会发到你的账号。接口未开放时不显示任何奖励数字。")
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)

            HStack(spacing: 8) {
                TextField("请输入邀请码", text: $inviteCode)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(AE.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(AE.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button {
                    Task { await bind() }
                } label: {
                    Text(binding ? "绑定中" : "绑定")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(AE.brandPurple, in: Capsule())
                }
                .buttonStyle(AevisPressStyle(scale: 0.96))
                .disabled(binding || inviteCode.isEmpty)
            }

            if let r = inviteResult {
                if r.ok {
                    Text("绑定成功：获得 \(r.points) 墨点")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AE.accent)
                } else {
                    Text(r.message.isEmpty ? "暂无数据" : r.message)
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                }
            } else {
                emptyLine("暂无数据")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.18)
        .shadow(color: AE.shadowColor, radius: 12, y: 5)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    // MARK: - 数据

    private func load() async {
        let freshConfig = await GrowthAPI.config(force: true)
        let freshActivities = await GrowthAPI.activities()
        await MainActor.run {
            config = freshConfig
            activities = freshActivities
        }
    }

    private func bind() async {
        await MainActor.run { binding = true }
        let result = await GrowthAPI.bindInvite(code: inviteCode)
        await MainActor.run {
            binding = false
            inviteResult = result
            if result.ok && result.message.isEmpty { showTip("绑定成功") }
        }
    }

    private func showTip(_ text: String) {
        withAnimation { tip = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { tip = "" } }
        }
    }
}
