import SwiftUI

// ============================================================================
// AEVIS · Paper 组件库（iOS）
//
// 与 Android 的 PaperKit.kt 一一对应；数值全部来自 design/spec/tokens.json
// （已生成在 AevisPaperTokens.swift 里的 Paper / PaperRadius / PaperStroke）。
//
// 纸感三条规矩（两端一样）：
//   1. 实描边 1.5pt + 硬投影（右下偏移、不虚化），像贴上去的纸片；
//   2. 圆角只用 11 / 13 / 14 / 16 这几档；
//   3. 分隔线一律虚线，不用实线灰条。
// ============================================================================

struct PaperCard<Content: View>: View {
    var radius: CGFloat = PaperRadius.lg
    /// 保留这个参数只是为了不破坏调用处；新版不再画错位黑块。
    var shadow: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        // 原来这里是「黑块偏移 + 1.5pt 黑描边」的纸感硬阴影。
        // 换成米白底之后那圈黑边显得很脏，Android 侧已经去掉，
        // iOS 这边直接用系统玻璃（aevisGlass 内部会按用户设置决定用不用玻璃）。
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .aevisGlass(cornerRadius: radius)
    }
}

struct PaperDashLine: View {
    var color: Color = Paper.line
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 1)
            .mask(
                HStack(spacing: 3) {
                    ForEach(0..<60, id: \.self) { _ in
                        Rectangle().frame(width: 3)
                    }
                }
            )
    }
}

struct PaperGroupLabel: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Paper.inkMuted)
            Rectangle().fill(Paper.ink).frame(height: 1.5)
        }
        .padding(.top, 14)
    }
}

struct PaperChip: View {
    let text: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Paper.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Paper.surface, in: RoundedRectangle(cornerRadius: PaperRadius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PaperRadius.sm, style: .continuous)
                        .strokeBorder(Paper.line, lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.sm, style: .continuous)
                        .fill(Paper.ink)
                        .offset(x: 1.5, y: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PaperIconButton: View {
    let glyph: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Paper.ink)
                .frame(width: 34, height: 34)
                .background(Paper.surface, in: RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous)
                        .strokeBorder(Paper.line, lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous)
                        .fill(Paper.ink)
                        .offset(x: 1.5, y: 1.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PaperAvatar: View {
    let name: String
    var size: CGFloat = 40
    var tint: Color = Paper.surface
    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundColor(Paper.ink)
            .frame(width: size, height: size)
            .background(tint, in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                    .strokeBorder(Paper.line, lineWidth: 1)
            )
    }
}

struct PaperRow<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    var leading: AnyView? = nil
    var dashed: Bool = true
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let leading { leading }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Paper.ink)
                    if let sub {
                        Text(sub)
                            .font(.system(size: 10.5))
                            .foregroundColor(Paper.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture { action?() }

            if dashed { PaperDashLine() }
        }
    }
}

extension PaperRow where Trailing == EmptyView {
    init(title: String, sub: String? = nil, leading: AnyView? = nil, dashed: Bool = true, action: (() -> Void)? = nil) {
        self.init(title: title, sub: sub, leading: leading, dashed: dashed, action: action) { EmptyView() }
    }
}

struct PaperSwitch: View {
    @Binding var on: Bool
    var body: some View {
        Button {
            withAnimation(PaperMotion.spring) { on.toggle() }
        } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? Paper.accent : Paper.surfaceSunken)
                    .frame(width: 38, height: 22)
                    .overlay(Capsule().strokeBorder(Paper.line, lineWidth: 1))
                Circle()
                    .fill(Paper.surface)
                    .frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(Paper.line, lineWidth: 1))
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

struct PaperPrimaryButton: View {
    let text: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(Paper.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Paper.accent, in: RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous)
                        .strokeBorder(Paper.line, lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: PaperRadius.md, style: .continuous)
                        .fill(Paper.ink)
                        .offset(x: 2.5, y: 2.5)
                )
        }
        .buttonStyle(.plain)
    }
}

struct PaperTabBar: View {
    let items: [(String, String)]
    @Binding var active: Int
    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let on = i == active
                Button {
                    withAnimation(PaperMotion.tabSpring) { active = i }
                } label: {
                    HStack(spacing: 6) {
                        Text(item.0).font(.system(size: 14))
                        if on {
                            Text(item.1)
                                .font(.system(size: 12, weight: .semibold))
                                .fixedSize()
                        }
                    }
                    .foregroundColor(on ? Paper.onAccent : Paper.inkMuted)
                    .padding(.horizontal, on ? 13 : 12)
                    .frame(height: 42)
                    .background(on ? Paper.accent : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        // 同样去掉黑描边和错位黑块，靠玻璃材质浮在内容上
        .aevisGlass(cornerRadius: 30)
    }
}
