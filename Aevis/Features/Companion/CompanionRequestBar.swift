import SwiftUI

/// 她想主动做点什么时，从顶上滑出来的那条申请。
///
/// 用户 2026-09-26：「AI 也可以主动的去申请……屏幕共享之类的，
/// **我们能用的东西它都能自动申请**」。
///
/// ## 为什么是"一条条"而不是弹一个对话框
/// 他可能正在打字、正在看朋友圈 —— 一个模态弹窗会**打断他手上这件事**，
/// 而且那副样子像系统权限弹窗，不像"她在问你"。所以做成从顶上滑进来的一条，
/// 不点它也能继续做别的（想不理就不理）。
struct CompanionRequestBar: View {

    let item: CompanionRequest.Item
    /// 点"接受"时回调 —— 界面据此真的去执行那件事。
    let onAccept: () -> Void
    let onDecline: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                // ⚠️ 图标用系统字号是故意的（不让它跟着正文字体变），
                // R7 那条规则专门放过了 SF Symbol。
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(settings.accentColor)

                Text(item.kind.title)
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)
            }

            if !item.reason.isEmpty {
                Text("「\(item.reason)」")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 看屏幕这一条要额外说清楚：iOS 不允许 App 自己开录屏，
            // 最后那一下必须他本人点系统的按钮 —— 不然他会以为"同意了就该开始了"。
            if item.kind == .screenShare {
                Text("同意之后还要点一次系统的录屏按钮 —— iOS 只认你手指那一下。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: onAccept) {
                    Text(item.kind.acceptTitle)
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .aevisGlass(cornerRadius: 13)
                }
                .buttonStyle(.plain)

                Button(action: onDecline) {
                    Text("不用了")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .aevisGlass(cornerRadius: 18)
        .shadow(color: Color.black.opacity(0.14), radius: 14, y: 4)
    }
}
