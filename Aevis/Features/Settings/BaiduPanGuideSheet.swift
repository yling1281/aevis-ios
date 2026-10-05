import SwiftUI

/// 登录之后弹**一次**的「把东西存到你自己的网盘」引导。
///
/// 用户 2026-10-03 的整条链路是：「每次退出就把聊天记录备份到百度网盘，
/// 换设备从网盘恢复，还有实时同步」。但**网盘授权得他点一下**才算数
/// （百度的规矩，App 拿不到别人的网盘）。以前这一下全靠他自己翻到设置里找，
/// 十有八九不会去点 —— 于是"同步"这件事从头到尾没发生过。
///
/// 所以登录成功后**默认弹这一次**，说清楚数据存在他自己的网盘里。
/// ⚠️ 只弹一次（`AppSettings.panGuideShown` 落盘记着）。
struct BaiduPanGuideSheet: View {

    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    private var accent: Color { settings.accentColor }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .font(.aevis(34))
                        .foregroundStyle(accent)
                        .padding(.top, 26)

                    Text("把你的东西存到你自己的网盘")
                        .font(.aevis(18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text("聊天记录、人设、记忆、头像 —— 都会备份到你自己的百度网盘里。"
                         + "换手机的时候登录同一个账号，内容会自动回到新手机上。")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        bullet("存的是你自己的网盘，不是我们的服务器。")
                        bullet("授权只是让它能往你网盘的一个文件夹里读写。")
                        bullet("不想用也可以，本地功能一样不少。")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aevisGlass(cornerRadius: 18)

                    Button {
                        goAuthorize()
                    } label: {
                        Text("去授权")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(accent)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        dismiss()
                    } label: {
                        Text("以后再说")
                            .font(.aevis(14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(AevisBackground().ignoresSafeArea())
            .navigationTitle("百度网盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .aevisScreen("网盘引导")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.aevis(13))
                .foregroundStyle(accent)
            Text(text)
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 送到「设置 → 百度网盘」那一张卡前面。
    private func goAuthorize() {
        AppRouter.shared.settingsFocus = "baidupan"
        AppRouter.shared.showSettings = true
        dismiss()
    }
}
