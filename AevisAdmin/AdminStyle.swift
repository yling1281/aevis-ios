import SwiftUI
import UIKit

/// 管理端的外观。**尽量只用系统的语义色**（`.primary` / `.secondary` /
/// `Color(uiColor: .systemGroupedBackground)`…），这样浅色、深色模式都不用单独写一套。
///
/// 品牌色跟网页后台（`web/admin.html` 的 `--brand`）对齐，两边看着是同一个东西。
enum AdminSkin {
    static let brand = Color(red: 0.357, green: 0.325, blue: 0.839)   // #5b53d6
    static let danger = Color(red: 0.753, green: 0.224, blue: 0.169)  // #c0392b
    static let warn = Color(red: 0.635, green: 0.396, blue: 0.039)

    static let pageMaxWidth: CGFloat = 760
    static let corner: CGFloat = 16
}

// MARK: - 卡片

/// 一张白底圆角卡。里面的每一行用 `AdminCardRow`。
///
/// ⚠️ 闭包参数必须**显式**写 init —— 靠存储属性上那层 `@ViewBuilder`
/// 去生成 memberwise init 不保险（拿不到就一片编译错误，一轮 CI 20 分钟）。
struct AdminCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: AdminSkin.corner, style: .continuous))
    }
}

/// 卡片里的一行：左边一段说明，右边放操作。
struct AdminCardRow<Leading: View, Trailing: View>: View {
    private let showsDivider: Bool
    private let leading: Leading
    private let trailing: Trailing

    init(
        showsDivider: Bool = true,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.showsDivider = showsDivider
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider {
                Rectangle()
                    .fill(Color(uiColor: .separator).opacity(0.5))
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
            HStack(alignment: .top, spacing: 12) {
                leading
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }
}

extension AdminCardRow where Trailing == EmptyView {
    /// 只有左边内容的那一行（`trailing` 传空就写这一句）。
    init(showsDivider: Bool = true, @ViewBuilder leading: () -> Leading) {
        self.init(showsDivider: showsDivider, leading: leading, trailing: { EmptyView() })
    }
}

/// 一行里的主标题 + 若干行小字。
struct AdminLine: View {
    var title: String
    var subtitle: String?
    var detail: String?
    var badge: (String, Color)?

    init(
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        badge: (String, Color)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.badge = badge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                if let badge {
                    Text(badge.0)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badge.1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(badge.1.opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 小零件

/// 分组小标题（网页后台那个灰色的 `h2`）。
struct AdminSectionTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 10)
    }
}

/// 卡片下面的说明文字。
struct AdminNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

struct AdminEmpty: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 26)
    }
}

/// 总览那个数字格。
struct AdminStatCell: View {
    var label: String
    var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

/// 小圆角按钮 —— 卡片右侧那些「封禁 / 解封 / 删除」。
struct AdminMiniButton: View {
    var title: String
    var tint: Color = .primary
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: filled ? .semibold : .medium))
                .foregroundStyle(filled ? .white : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(filled ? tint : Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 页面外壳

/// 所有页面共用：统一下拉刷新、错误提示、吐司、iPad 上限制一下宽度。
///
/// ⚠️ 一个 tab / 一个侧栏项 **只套一层** `AdminPage` ——
/// 它自带 `ScrollView`，套两层就是嵌套滚动，手机上很难用。
struct AdminPage<Content: View>: View {
    private let title: String
    private let content: Content

    @EnvironmentObject private var store: AdminStore

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: AdminSkin.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshAll() }
        .alert("出问题了", isPresented: Binding(
            get: { store.errorText != nil },
            set: { if !$0 { store.errorText = nil } }
        )) {
            Button("知道了", role: .cancel) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
        // ⚠️⚠️ 提示条放在**顶部**，不放底部 —— 这是真栽过的：
        //    底部会被 TabView 的标签栏挡掉，用户点「封禁」之后**看不到任何反馈**，
        //    以为没成功就反复点。服务端日志里那 13 次连点（封/解封来回切）就是这么来的。
        //    顶部落在导航栏下面，标签栏够不着。
        .overlay(alignment: .top) {
            if let toast = store.toast {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(toast)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.88))
                .clipShape(Capsule())
                .padding(.top, 8)
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task(id: toast) {
                    // 2.6 秒：1.9 秒时他往往还在看列表，容易以为"什么都没发生"
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    store.toast = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
    }
}

/// 一键复制的小按钮（发码 / 钥匙都要用）。
struct AdminCopyButton: View {
    var text: String
    var label: String = "复制"

    @State private var copied = false

    var body: some View {
        AdminMiniButton(title: copied ? "已复制" : label, tint: AdminSkin.brand) {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        }
    }
}
