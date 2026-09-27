import SwiftUI
import UIKit

/// 一块**能收起的内容**：可点的标题（带箭头、可选条数）+ 内容。
///
/// 为什么要有它 —— 用户 2026-09-27 的原话：
/// 「**所有的功能区域，你都是可以缩起的，就防止很多东西**」。
/// 管理端几页列表（订单、解锁码、账号、崩溃…）滚起来没完，收起来一眼就能看到全貌。
///
/// ⚠️ 收起状态**按 `key` 记在 UserDefaults 里**，不是每次进来都展开 ——
/// 不然"我明明收起来了，怎么又自己开了"，那比不能收还烦。
struct AdminFold<Content: View>: View {
    private let title: String
    private let count: Int?
    private let content: Content

    @AppStorage private var folded: Bool

    /// - Parameters:
    ///   - key: 记忆用的键，**换文案不要换它**（否则用户收起来的状态会丢）
    ///   - defaultFolded: 第一次见时的默认状态
    init(
        _ title: String,
        key: String,
        count: Int? = nil,
        defaultFolded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.content = content()
        // ⚠️ `@AppStorage` 在自定义 init 里必须走 `_folded = AppStorage(...)`，
        //    不能写 `folded = ...`（那个是改 get-only 的计算属性，编译不过）
        _folded = AppStorage(wrappedValue: defaultFolded, "aevis.admin.fold." + key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !folded { content }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { folded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folded ? -90 : 0))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .padding(.bottom, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(folded ? "已收起" : "已展开")
    }
}

/// 搜索框 —— 账号页和订单页共用一份。
///
/// 抽出来的原因很实际：两处各写一遍的话，清空按钮、自动大写那些小处理
/// 一定会有一边漏掉（账号页原来就是自己一套）。
struct AdminSearchField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .font(.system(size: 14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
