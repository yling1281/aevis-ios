import SwiftUI

// --------------------------------------------------------------------------
// 码支付侧共用的文案转换
// --------------------------------------------------------------------------

func payTypeText(_ t: String) -> String {
    switch t {
    case "wechat": return "微信"
    case "alipay": return "支付宝"
    default: return t.isEmpty ? "—" : t
    }
}

func payTypeTint(_ t: String) -> Color {
    switch t {
    case "wechat": return .green
    case "alipay": return .blue
    default: return .secondary
    }
}

/// 订单状态：0 待支付 / 1 成功 / 2 失败 / 5 过期
func payStatusText(_ s: Int) -> String {
    switch s {
    case 0: return "待支付"
    case 1: return "已支付"
    case 2: return "已关闭"
    case 5: return "已过期"
    default: return "未知(\(s))"
    }
}

/// 映射到 `Tone.color` 的四档：1 好 / 2 待处理 / 3 停用 / 0 中性
func payStatusTone(_ s: Int) -> Int {
    switch s {
    case 1: return 1
    case 0: return 2
    case 2: return 3
    default: return 0
    }
}

/// 通道等级：1 优先级 / 2 路线2 / 3 备用
func payTierTint(_ tier: Int) -> Color {
    switch tier {
    case 1: return .red
    case 2: return .orange
    default: return .secondary
    }
}

/// 到账流水状态：new / matched / ignored
func payMatchText(_ s: String) -> String {
    switch s {
    case "matched": return "已认单"
    case "ignored": return "已忽略"
    case "new": return "待认单"
    default: return s.isEmpty ? "—" : s
    }
}

func payMatchTone(_ s: String) -> Int {
    switch s {
    case "matched": return 1
    case "new": return 2
    case "ignored": return 3
    default: return 0
    }
}

// --------------------------------------------------------------------------
// 列表行 / 详情
// --------------------------------------------------------------------------

/// 通用的一行。**故意不直接用 `[[String: Any]]`** ——
/// SwiftUI 的 `ForEach` 要 `Identifiable`，而字典不满足，硬套 `id: \.self` 编不过。
struct PayRow: Identifiable {
    let id: String
    let title: String
    var sub: String = ""
    var right: String = ""
    var tone: Int = 0
    var chip: String = ""
    var chipTint: Color = .accentColor
    /// 点进去之后逐行显示的键值对
    var detail: [(String, String)] = []
}

struct PayRowCell: View {
    let row: PayRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !row.chip.isEmpty {
                        Chip(text: row.chip, tint: row.chipTint)
                    }
                }
                if !row.sub.isEmpty {
                    Text(row.sub)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if !row.right.isEmpty {
                Text(row.right)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Tone.color(row.tone))
            }
        }
        .padding(.vertical, 3)
    }
}

struct PayDetailView: View {
    let row: PayRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if !row.sub.isEmpty {
                    Text(row.sub).font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(row.detail.enumerated()), id: \.offset) { _, kv in
                        KVRow(k: kv.0, v: kv.1, mono: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 小卡片容器（码支付侧统一用它，跟素材后台视觉一致）
///
/// ⚠️ 这里**手写 init**、不靠 `@ViewBuilder let content` 的自动合成 ——
///    属性上的 `@ViewBuilder` 能不能生成带 builder 的成员初始化器，
///    在不同 Swift 版本上表现不一致；自己写一行，永远编得过。
struct PayCard<C: View>: View {
    let title: String
    let content: () -> C

    init(title: String, @ViewBuilder content: @escaping () -> C) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
    }
}
