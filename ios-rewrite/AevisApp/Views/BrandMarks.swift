import SwiftUI

/// 支付渠道的品牌标识与整行组件（2026-11-25）。
///
/// 用户原话：「为什么你那个微信的话只有框啊」—— 之前渠道行只有一个彩色圆圈里放个
/// 「微」/「A」字母，看着像占位框而不是官方渠道。这里收敛成真品牌标识：
/// - 微信：绿底（官方 #07C160）+ 双气泡字形（SF Symbol `bubble.left.and.bubble.right.fill`，
///   与官方「两个重叠对话框」的视觉结构一致）；
/// - 支付宝：蓝底（官方 #1677FF）+ 官方「支」字（支付宝 Logo 就是「支」）。
///
/// 为什么不用官方 PNG：这类商标资源要跟着米粒级尺寸适配（40pt / 28pt / 20pt 三档），
/// 位图在 @2x/@3x 下会糊；用矢量字形 + 官方色，任何尺寸都锐利，也不用往包里塞二进制资源。
/// 颜色一律取 `AE.payWechat` / `AE.payAlipay`（`Models.swift` 里的品牌色常量），
/// 不要在别处再写一遍色值。
enum PayBrand: String, CaseIterable, Identifiable {
    case wechat
    case alipay

    var id: String { rawValue }

    /// 渠道名（用户可见）
    var title: String {
        switch self {
        case .wechat: return "微信支付"
        case .alipay: return "支付宝"
        }
    }

    /// 一句话说明（渠道行副标题）
    var note: String {
        switch self {
        case .wechat: return "微信扫聚合码付款，到账自动提示"
        case .alipay: return "微信或支付宝扫同一个码付款"
        }
    }

    /// 品牌主色
    var tint: Color {
        switch self {
        case .wechat: return AE.payWechat
        case .alipay: return AE.payAlipay
        }
    }

    /// 下单用的 payType（与后端 `epay`/`memberOrder` 的 `pay_type` 对齐）
    var payType: String {
        switch self {
        case .wechat: return "wxpay"
        case .alipay: return "alipay"
        }
    }
}

/// 品牌圆形标识：品牌色实心底 + 白色官方字形。
///
/// 用法：`PayBrandMark(brand: .wechat, size: 40)`
struct PayBrandMark: View {
    let brand: PayBrand
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle()
                .fill(brand.tint)
                .frame(width: size, height: size)

            switch brand {
            case .wechat:
                // 双气泡：微信官方标识的核心结构（两个重叠对话框 + 四只眼睛）。
                // SF Symbol 的 bubble.left.and.bubble.right.fill 就是同一结构，眼睛用两个白点补。
                ZStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: size * 0.52, weight: .regular))
                        .foregroundStyle(.white)
                }
            case .alipay:
                // 支付宝 Logo 本体就是「支」字，用重体让它在小尺寸下也认得出来。
                Text("支")
                    .font(.system(size: size * 0.56, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .offset(y: -size * 0.02)
            }
        }
        .accessibilityLabel(brand.title)
    }
}

/// 支付渠道整行：品牌标识 + 名称 + 说明 + 右箭头。
///
/// 商城（墨点/按次）与会员页共用同一个组件，避免两边样式越改越不一样。
/// 外层不给背景，由调用方决定卡片质感（两页都是 `glassCard`）。
struct PayChannelRow: View {
    let brand: PayBrand
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                PayBrandMark(brand: brand, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(brand.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                    Text(brand.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.textSecondary.opacity(0.45))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16, material: .thin, tintOpacity: 0.16)
        }
        .buttonStyle(AevisPressStyle(scale: 0.97))
    }
}
