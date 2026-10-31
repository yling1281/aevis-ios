import SwiftUI

/// 「怎么使用 / 规则 / 常见问题」—— **原生页面**（2026-10-31 改）。
///
/// ## 为什么不再开网页
/// 原来这一行是 `AevisHosts.siteURL("/rules")`，而 `siteDomain` 是 **`sucai.aevis.cn`**
/// （素材站）—— 实测 `https://sucai.aevis.cn/rules` 直接 301，
/// `https://aevis.cn/rules` 返回的是**官网首页**（16661 字节，和 `/faq`、`/terms` 一模一样），
/// 因为站上根本没有 `/rules` 这个页，走的是 SPA 兜底。
/// 用户点「使用规则 / 常见问题」看到的是官网首页 —— 这就是他说的「切换一下」。
///
/// 现在改成原生页：不依赖域名、不依赖网络、改文案不用重新部署网站。
struct RulesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("怎么开始用", "1.circle") {
                        step(1, "在「账号」里注册或登录（也可以直接用微信登录）")
                        step(2, "去「\(Pronoun.current)」里设好名字、性格、音色")
                        step(3, "在「积分」里充一点，云端模型按用量扣积分")
                        step(4, "回「消息」开聊；想听歌就进「发现 → 网易云音乐」")
                    }

                    section("规则", "checklist") {
                        bullet("一个账号只给自己用，不要外借或转卖。")
                        bullet("不要用 ta 生成违法内容、骚扰别人、冒充真人骗人。")
                        bullet("云端模型按 token 扣积分，扣了不退（见下方「退款」）。")
                        bullet("你和 ta 的聊天记录默认存在**你自己的设备**和你的账号下，我们不做二次利用。")
                        bullet("会员到期后账号和数据都留着，只是云端模型会停；续费即可恢复。")
                    }

                    section("常见问题", "questionmark.circle") {
                        qa("为什么要充积分？",
                           "AI 回复走的是云端模型，按用量收费。1 元 = 200 积分，按模型官方价的 1.5 倍折算，用多少扣多少，不订阅也能用。")
                        qa("换手机，聊天记录会丢吗？",
                           "不会。登录同一个账号后，记录会从云端同步回来（设置里可以手动「立即同步」）。")
                        qa("会员和积分是一回事吗？",
                           "不是。会员解锁功能和时长，积分是给云端模型用的「电」。会员到期不影响已有积分。")
                        qa("ta 说的话是真人吗？",
                           "不是。所有回复都由模型生成。请把它当成一个角色，不要据此做重要决定。")
                        qa("健康 / 经期数据会上传吗？",
                           "不会。读写都在本机的健康 App 里，App 只在你主动问起时读一次摘要。")
                        qa("音乐为什么有时放不出来？",
                           "网易云那条是逆向接入，没有官方授权：版权受限的歌、或需要会员的歌会放不了。建议登录一个不常用的小号。")
                        qa("能不能退款？",
                           "积分一旦用于模型调用就无法退回。充错了（还没用过）可以联系客服人工处理。")
                        qa("怎么联系客服？",
                           "「我的 → 账号」里有客服入口（企业微信）。工作时间内回复。")
                    }

                    section("免责声明", "doc.text") {
                        bullet("本 App 是个人项目，AI 输出不保证准确，请自行判断。")
                        bullet("音乐、健康等第三方数据来自对应系统/平台，版权归原方。")
                        bullet("因网络、第三方服务变更造成的功能不可用，我们会尽快修，但不承担连带损失。")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("怎么使用 · 规则 · 常见问题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 零件

    private func section<Content: View>(
        _ title: String,
        _ symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.aevis(13, weight: .medium))
                Text(title)
                    .font(.aevis(15, weight: .semibold))
            }
            .foregroundStyle(.primary)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .aevisGlass(cornerRadius: 20)
    }

    private func step(_ index: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index)")
                .font(.aevisMono(11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(AppSettings.shared.accentColor))
            Text(text)
                .font(.aevis(13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            Text(text)
                .font(.aevis(13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func qa(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(q)
                .font(.aevis(13.5, weight: .medium))
                .foregroundStyle(.primary)
            Text(a)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
