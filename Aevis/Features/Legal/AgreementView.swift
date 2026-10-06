import SwiftUI
import Foundation

/// 用户协议正文。**纯文本常量** —— 不联网，且**不含任何密钥、服务器地址、后台路径**。
///
/// ⚠️ 改了这份正文，就要把 `AgreementStore.currentVersion` 一起 +1 ——
///    否则老用户不会被重新弹一次。
///
/// ⚠️ 这一份属于界面文案：不出现硬编码的性别代词，一律中性表述。
private let agreementText = """
一、服务说明
Aevis 是一款 AI 虚拟伴侣软件。这里的 AI 由大语言模型生成，不是真人，其言行均为程序生成。

二、使用资格
用户应具备完全民事行为能力；未成年人须在监护人同意与陪同下使用。

三、数据与隐私
聊天记录、人设、日记等默认只存在用户本机；用户可自行选择备份到用户自己的网盘；我们不上传、不查看用户的聊天内容。用户自填的模型 API Key 仅保存在本机。

四、费用
本软件为一次性付费软件（12 元），通过非商店渠道分发，用户自行完成签名安装。

五、AI 生成内容免责
AI 输出可能不准确、不完整或不符合预期，不构成医疗、法律、金融等任何专业建议，请勿据此做重要决定。

六、用户自备模型服务
模型调用费用由用户自行承担，与本软件无关。

七、禁止用途
不得利用本软件从事违反法律法规、侵犯他人权益的行为。

八、协议变更
协议更新后版本号会提升，届时将再次提示用户确认。
"""

/// 用户协议页 —— **未同意时这是 App 唯一能看到的一屏。**
///
/// 它由 `AevisApp` 在最外层条件渲染：没同意时整棵主界面（`RootView`）
/// 都不构造，所以这**不是能被划走的 sheet**，而是"不同意就真的用不了"。
///
/// 布局：标题 + 可滚动正文（可选中复制）+ 底部两个固定按钮。
/// 深浅色都跟着系统走（正文用 `Color.primary` / 次要文字用 `.secondary`）。
struct AgreementView: View {

    /// 同意状态。点「同意并继续」后 `accepted` 变 true，外层立刻切到主界面。
    @ObservedObject private var agreement = AgreementStore.shared

    /// 主题色 —— 主按钮的填充色跟着用户设置走。
    @ObservedObject private var settings = AppSettings.shared

    /// 点了「不同意」先弹这个，确认了才退。
    @State private var showDeclineAlert = false

    var body: some View {
        ZStack {
            AevisBackground()

            VStack(spacing: 0) {
                header
                scrollBody
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 14)
        }
        .alert("需要同意本协议才能使用 Aevis。", isPresented: $showDeclineAlert) {
            Button("退出 App", role: .destructive) {
                BlackBox.tap("协议 · 退出 App")
                // 不上架 App Store，按老板要求「不同意即退出」：
                // 这是侧载分发的软件，用户在确认后直接结束进程。
                exit(0)
            }
            Button("返回", role: .cancel) {
                BlackBox.tap("协议 · 返回")
            }
        }
        // 进这一页也记一笔 —— 项目约定：进了哪一屏、点了哪个按键都要能查。
        //（见 `BlackBoxUI.swift`。之前这一屏完全没有记录，出问题查不到现场。）
        .aevisScreen("用户协议")
    }

    // MARK: - 标题

    private var header: some View {
        VStack(spacing: 6) {
            Text("用户协议与免责声明")
                .font(.aevis(22, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("版本 \(AgreementStore.currentVersion)")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
    }

    // MARK: - 正文（可滚动、可选中）

    private var scrollBody: some View {
        ScrollView {
            Text(agreementText)
                .font(.aevis(14))
                .foregroundStyle(.primary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 底部两个按钮

    private var footer: some View {
        VStack(spacing: 10) {
            // ⚠️ 用 `LoggedButton`：点击**一定会先记一笔**再执行
            //（比 `.aevisTap` 稳，见 `BlackBoxUI.swift`）。下次出问题就有现场。
            LoggedButton("协议 · 同意并继续") {
                agreement.accept()
            } label: {
                Text("同意并继续")
                    .font(.aevis(16.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(settings.accentColor)
                    )
            }
            .buttonStyle(.plain)

            LoggedButton("协议 · 不同意") {
                showDeclineAlert = true
            } label: {
                Text("不同意")
                    .font(.aevis(15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 16)
    }
}
