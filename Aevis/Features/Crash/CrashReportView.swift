import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 上次异常退出 → **整个屏幕报一个错误码**。
///
/// ## 用户定的口径（2026-09-26）
/// 「如果闪退了，你应该是整个屏幕报错误码，然后有那个错误码」
/// 「把错误码发给他（智能客服），他也能给你反馈」。
///
/// 也就是说：**别再让用户翻设置、复制一大段东西**。崩了就弹这一屏，
/// 上面一个大大的码，他抄下来发出去就行。
///
/// ## 码是怎么来的（这点很重要）
/// **不是随机的，是算出来的**：`版本 + 崩之前最后一个动作`。
/// 所以同一个故障每次都是同一个码 —— 十个用户报同一个码，
/// 就是卡在同一处，不用挨个去要完整日志。
/// 反过来，如果码每次都变，说明是随机崩溃（线程/内存那类）。
///
/// ## 为什么放在 `fullScreenCover` 里而不是某个 tab
/// 崩了就是崩了，得像门禁页那样**盖住整个 App** —— 否则用户会先去聊天，
/// 等到想起来反馈的时候现场已经滚没了。
struct CrashReportView: View {

    @ObservedObject private var settings = AppSettings.shared

    /// 关掉这一屏（记录本身留着）。
    let onClose: () -> Void

    @State private var copiedCode = false
    @State private var copiedAll = false

    private var code: String { BlackBox.crashCode }
    private var lines: [String] { BlackBox.lastCrashLines }

    var body: some View {
        ZStack {
            AevisBackground()

            ScrollView {
                VStack(spacing: 0) {
                    badge
                        .padding(.top, 46)

                    Text("上次退出得不正常")
                        .font(.aevis(21, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 18)

                    Text("App 上次没能正常结束 —— 多半是崩了。\n下面这个码就是那次的现场。")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .padding(.horizontal, 6)

                    codeCard
                        .padding(.top, 22)

                    stepsCard
                        .padding(.top, 14)

                    copyAllButton
                        .padding(.top, 16)

                    closeButton
                        .padding(.top, 8)

                    Text("发给客服（群里那个智能客服）报这个码就行，\n不用你自己去翻日志。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 40)
                }
                .padding(.horizontal, 22)
            }
        }
    }

    // MARK: - 组件

    private var badge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(.orange)
    }

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("错误码")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 7)

            rule

            HStack(spacing: 10) {
                Text(code)
                    // 等宽 + 跟着字号设置走。抄码的时候少看错一位。
                    .font(.aevisMono(30, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Spacer(minLength: 8)

                Button {
                    copy(code, into: $copiedCode)
                } label: {
                    Text(copiedCode ? "已复制" : "复制")
                        .font(.aevis(13.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(settings.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            rule

            Text("同一个故障每次算出来都是这个码；要是每次都不一样，\n那说明是随机崩的（线程/内存那类）。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2.5)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
        }
        .aevisGlass(cornerRadius: 18)
    }

    /// 崩之前最后几步 —— 给用户看一眼"它死在哪儿"，
    /// 也方便他判断要不要一起发过来。
    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("崩之前最后几步")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 7)

            rule

            if lines.isEmpty {
                Text("（这次没记到 —— 可能是启动阶段就没了）")
                    .font(.aevis(12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    // 只显示最后 8 行：再多用户也不会看，而且这一屏的主角是那个码
                    ForEach(Array(lines.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.aevisMono(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
        .aevisGlass(cornerRadius: 18)
    }

    private var copyAllButton: some View {
        Button {
            copy(BlackBox.report(), into: $copiedAll)
        } label: {
            Text(copiedAll ? "已复制，去发给客服" : "复制完整诊断信息")
                .font(.aevis(15.5, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            BlackBox.acknowledgeCrash()
            onClose()
        } label: {
            Text("知道了，接着用")
                .font(.aevis(14))
                .foregroundStyle(settings.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: - 复制

    private func copy(_ text: String, into flag: Binding<Bool>) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
        withAnimation(.easeOut(duration: 0.15)) { flag.wrappedValue = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            withAnimation(.easeOut(duration: 0.2)) { flag.wrappedValue = false }
        }
    }
}
