import SwiftUI

/// 首页样式切换：微信式 / 个人中心式。
///
/// 用户 2026-11-11：「两个 UI 让用户可以自己选择」。
/// 两套共用同一批功能，只是首屏排版不同 —— 所以只切 `AppSettings.homeStyle`，
/// 页面本身在 `MeView` 里按这个值分支，不做两套导航栈。
struct HomeStyleCard: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("首页样式")
                .font(.aevis(14, weight: .semibold))

            Picker("首页样式", selection: $settings.homeStyle) {
                Text("微信式").tag("wechat")
                Text("个人中心").tag("personal")
            }
            .pickerStyle(.segmented)

            Text(settings.isPersonalHome
                 ? "打开就是「我的」：大头像 + 名字、活动横幅、一排圆形入口，联系人和朋友圈往下排。"
                 : "跟微信一样：聊天 / 通讯录 / 发现 / 我，四个 tab。")
                .font(.aevis(12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
