import SwiftUI

/// 免责声明 —— **整页**，文字全部在 App 里（不依赖网络）。
///
/// 为什么要有一页：这个项目会碰到别人的账号（QQ 机器人、网易云、百度网盘），
/// 也会让别人往手机上装东西。**风险得摆在明面上**，不能让朋友装完才知道。
/// 内容与网站上那一页（`https://lingyan.cyou/disclaimer.html`）是同一份口径，
/// 改的时候两边一起改。
struct DisclaimerView: View {

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared

    /// 网页版。App 里看不够、想转发给别人的话，点这个。
    static let webURL = "https://lingyan.cyou/disclaimer.html"

    private struct Block: Identifiable {
        let id = UUID()
        var title: String
        var paragraphs: [String] = []
        var bullets: [String] = []
    }

    private static let updated = "最后更新：2026 年 9 月 25 日"

    private static let blocks: [Block] = [
        Block(title: "一、这不是官方产品",
              paragraphs: [
                "Aevis 与腾讯、网易、百度、字节跳动、Apple 及任何第三方公司均无关联，"
                + "未经它们授权、认可或赞助。项目里用到的第三方平台功能，都是使用者自行配置的。"
              ]),
        Block(title: "二、使用风险由你自行承担",
              paragraphs: [
                "本软件按「现状」提供，不附带任何明示或暗示的担保，包括但不限于可用性、"
                + "无中断、无错误、适合特定用途。我们不对以下情况承担责任：",
                "关于 iOS 签名（很重要）：本 App 没有上架 App Store，是通过第三方签名证书装的。"
                + "证书可能被苹果吊销 —— 一旦掉签，App 会直接打不开，需要重新签名安装。"
                + "而重新签名后安装通常要先删掉原来的 App，"
                + "聊天记录、人设、记忆会跟着一起消失。"
                + "所以请定期用 App 里的「分享与搬家」导出备份，"
                + "把备份文件存到「文件」App 或发给自己。",
                "签名服务是第三方提供的服务，和开源项目本身无关。它的期限、掉签之后怎么处理，"
                + "以你购买时跟对方说好的为准。"
              ],
              bullets: [
                "软件无法运行、功能异常、崩溃、闪退",
                "数据丢失或损坏（请自行备份重要内容）",
                "因使用或无法使用本软件造成的任何直接或间接损失",
                "你自行配置的人设、提示词、聊天内容所引发的一切后果"
              ]),
        Block(title: "三、账号与注册码",
              bullets: [
                "注册码一人一个，不得转卖、转让或公开分享。",
                "你需对自己账号下发生的一切操作负责。",
                "如发现滥用（批量领取、脚本刷码、倒卖注册码等），我们有权停止发放、"
                + "作废相关注册码、停止相关账号的登录。",
                "账号后端是个人自建的小型服务，可能随时停机、迁移或变更。"
                + "停机期间你手机上的聊天记录不受影响。"
              ]),
        Block(title: "四、第三方服务",
              paragraphs: [
                "App 内部分功能会调用第三方平台（例如网易云音乐、百度网盘、QQ 开放平台、抖音等）。"
                + "这些功能使用的是该平台公开或非公开的接口，可能随时失效、变更或被限制 —— "
                + "我们会尽力修，但不做任何保证。",
                "使用时请遵守对应平台的用户协议与相关法律法规。由此导致的账号被限制、封禁、"
                + "内容被删除等风险，由使用者自行承担。"
              ]),
        Block(title: "五、你的数据存在哪里",
              paragraphs: [
                "只存在你手机上：人设、聊天记录、记忆、图片、你填的 API Key（存在系统钥匙串）。"
                + "这些内容不会上传到我们的服务器，我们也不读取、不存储、不分析。",
                "服务器上只有：你的登录邮箱、注册时间、登录时间、登录 IP、设备类型。"
                + "它们只用于登录验证与账号安全。",
                "但请注意：聊天内容会发送给你自己配置的模型服务商，那部分由你与它之间的条款约束，"
                + "与我们无关。"
              ]),
        Block(title: "六、AI 生成内容",
              paragraphs: [
                "AI 生成的内容可能不准确、不恰当或令人误解。请勿把它当作医疗、法律、金融等"
                + "专业建议，也不要作为任何重要决策的唯一依据。"
              ]),
        Block(title: "七、内容与行为",
              paragraphs: ["使用本软件时，你不得："],
              bullets: [
                "生成、传播违反中华人民共和国法律法规的内容",
                "骚扰、侮辱、冒充他人，或侵害他人合法权益",
                "将本软件用于任何违法用途"
              ]),
        Block(title: "八、未成年人",
              paragraphs: [
                "本软件面向成年人。如果你未满 18 周岁，请在监护人知情并同意的前提下使用。"
              ]),
        Block(title: "九、开源许可",
              paragraphs: [
                "本软件基于 GPL-3.0 协议开源，是免费软件，不提供任何形式的商业担保。"
                + "你可以按该协议使用、修改、分发它 —— 包括收费分发。",
                "按 GPL-3.0 的要求：即使你为「代签名 / 代安装」付过钱，"
                + "你依然有权拿到本软件的对应源代码，而且不用为此再付一笔。"
                + "源码在 GitHub 上的 yling1281/aevis-ios。",
                "你付的那笔钱，买的是签名与安装这一项服务 —— 它和软件本身是两回事。"
              ]),
        Block(title: "十、声明变更",
              paragraphs: [
                "本声明可能随时更新，更新后会改上面的日期。继续使用即视为接受更新后的版本。"
              ])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    lead
                    ForEach(Self.blocks) { block in
                        section(block)
                    }
                    webRow
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("免责声明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    // MARK: - 头部

    private var lead: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aevis 是一个个人开发的、开源的技术项目，按「现状」提供，不带任何担保。"
                 + "使用它的风险由你自己承担。软件本身基于 GPL-3.0 开源 —— "
                 + "如果你是为「代签名 / 代安装」付了钱，那笔钱买的是服务，不是软件本身。")
                .font(.aevis(14.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.updated)
                .font(.aevis(12))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 20)
    }

    // MARK: - 每一节

    private func section(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(block.title)
                .font(.aevis(15.5, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(block.paragraphs, id: \.self) { text in
                Text(text)
                    .font(.aevis(13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(block.bullets, id: \.self) { text in
                HStack(alignment: .top, spacing: 8) {
                    Text("·")
                        .font(.aevis(13.5))
                        .foregroundStyle(settings.accentColor)
                    Text(text)
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    // MARK: - 网页版

    private var webRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("想转发给别人，或者想在网上看这一页：")
                .font(.aevis(12.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.webURL)
                .font(.aevisMono(12))
                .foregroundStyle(settings.accentColor)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }
}
