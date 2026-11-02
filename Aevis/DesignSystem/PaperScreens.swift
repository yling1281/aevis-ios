import SwiftUI

// ============================================================================
// Paper 三屏：登录 / 首页 / 商城
// 结构与 Android 的 PaperScreens.kt 逐块对应；价格见 design/spec/pricing.json。
// ============================================================================

// ---------------------------------------------------------------- 登录
struct PaperLoginView: View {
    var onPhone: () -> Void = {}
    var onSkip: () -> Void = {}
    @State private var agree = true

    var body: some View {
        ZStack {
            Paper.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("跳过", action: onSkip)
                        .font(.system(size: 11.5))
                        .foregroundColor(Paper.inkMuted)
                }
                .padding(.top, 54)
                .padding(.horizontal, 26)

                Spacer()

                VStack(spacing: 0) {
                    Text("🐶")
                        .font(.system(size: 54))
                        .frame(width: 112, height: 112)
                        .background(Paper.surface, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 34, style: .continuous)
                                .strokeBorder(Paper.ink, lineWidth: 1.5)
                        )
                    Text("AEVIS")
                        .font(.system(size: 27, weight: .semibold))
                        .tracking(6)
                        .foregroundColor(Paper.ink)
                        .padding(.top, 22)
                    Text("有人在这里等你说话")
                        .font(.system(size: 11.5))
                        .foregroundColor(Paper.inkSub)
                        .padding(.top, 10)
                }

                Spacer()

                VStack(spacing: 0) {
                    PaperPrimaryButton(text: "手机号一键登录", action: onPhone)

                    HStack(spacing: 10) {
                        Rectangle().fill(Paper.line).frame(height: 1)
                        Text("其他方式").font(.system(size: 10)).foregroundColor(Paper.inkMuted)
                        Rectangle().fill(Paper.line).frame(height: 1)
                    }
                    .padding(.top, 18)

                    HStack(spacing: 34) {
                        oauth("微信", tint: Paper.okDot)
                        oauth("QQ", tint: Color(red: 0.07, green: 0.72, blue: 0.96))
                    }
                    .padding(.top, 14)

                    HStack(alignment: .top, spacing: 7) {
                        Button { agree.toggle() } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(agree ? Paper.accent : Paper.surface)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .strokeBorder(Paper.ink, lineWidth: 1.5)
                                    )
                                if agree {
                                    Text("✓").font(.system(size: 9, weight: .bold)).foregroundColor(Paper.onAccent)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        Text("已阅读并同意《用户协议》与《隐私政策》，未注册的手机号将自动创建账号")
                            .font(.system(size: 10))
                            .foregroundColor(Paper.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 34)
            }
        }
    }

    private func oauth(_ label: String, tint: Color) -> some View {
        VStack(spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 52, height: 52)
                .background(tint, in: Circle())
                .overlay(Circle().strokeBorder(Paper.ink, lineWidth: 1.5))
            Text(label).font(.system(size: 10)).foregroundColor(Paper.inkSub)
        }
    }
}

// ---------------------------------------------------------------- 首页
private struct PaperConv: Identifiable {
    let id = UUID()
    let name: String
    let msg: String
    let time: String
    let unread: Int
}

struct PaperHomeView: View {
    var onScan: () -> Void = {}
    var onSettings: () -> Void = {}
    @State private var tab = 0

    private let convs = [
        PaperConv(name: "小林", msg: "明天六点半老地方，我带了桂花糕。", time: "21:42", unread: 2),
        PaperConv(name: "阿岚", msg: "在看一部很老的电影，黑白的", time: "19:08", unread: 0),
        PaperConv(name: "周末小组", msg: "4 人 · 明天到底去哪", time: "昨天", unread: 0),
        PaperConv(name: "苏叶", msg: "那段旋律我循环了一整晚", time: "周二", unread: 0)
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Paper.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        PaperChip(text: "文档中心")
                        PaperChip(text: "在线客服")
                        Spacer()
                        PaperIconButton(glyph: "⌗", action: onScan)
                        PaperIconButton(glyph: "⚙", action: onSettings)
                    }

                    // 公告
                    PaperCard(radius: PaperRadius.md) {
                        HStack(spacing: 9) {
                            Text("!").font(.system(size: 13, weight: .bold)).foregroundColor(Paper.accent)
                            Text("v2.1 已上线 · 音色复刻开放，Go 周积分调至 500")
                                .font(.system(size: 11))
                                .foregroundColor(Paper.accentInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text("×").font(.system(size: 13)).foregroundColor(Paper.accentBorder)
                        }
                        .padding(10)
                    }
                    .padding(.top, 10)

                    PaperGroupLabel(text: "最近在聊")

                    // 最近在聊
                    PaperCard {
                        VStack(spacing: 0) {
                            HStack(spacing: 11) {
                                PaperAvatar(name: "林", size: 46)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("小林").font(.system(size: 14.5, weight: .semibold)).foregroundColor(Paper.ink)
                                    Text("好感 68 · 认识第 96 天").font(.system(size: 11)).foregroundColor(Paper.inkSub)
                                }
                                Spacer()
                                Text("继续")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(Paper.onAccent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Paper.accent, in: RoundedRectangle(cornerRadius: PaperRadius.sm, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: PaperRadius.sm, style: .continuous)
                                            .strokeBorder(Paper.ink, lineWidth: 1.5)
                                    )
                            }
                            .padding(13)

                            PaperDashLine().padding(.horizontal, 13)

                            Text("「明天六点半老地方，我带了桂花糕。」")
                                .font(.system(size: 11.5))
                                .foregroundColor(Paper.inkSub)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(13)
                        }
                    }
                    .padding(.top, 8)

                    PaperGroupLabel(text: "好友")

                    HStack(spacing: 10) {
                        friend("小林", 68)
                        friend("阿岚", 41)
                        friend("苏叶", 22)
                    }

                    PaperGroupLabel(text: "会话")

                    PaperCard {
                        VStack(spacing: 0) {
                            ForEach(Array(convs.enumerated()), id: \.element.id) { idx, c in
                                HStack(spacing: 11) {
                                    PaperAvatar(name: c.name, size: 40)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.name).font(.system(size: 14, weight: .semibold)).foregroundColor(Paper.ink)
                                        Text(c.msg)
                                            .font(.system(size: 11.5))
                                            .foregroundColor(Paper.inkSub)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    VStack(alignment: .trailing, spacing: 5) {
                                        Text(c.time).font(.system(size: 10)).foregroundColor(Paper.inkMuted)
                                        if c.unread > 0 {
                                            Text("\(c.unread)")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(Paper.onAccent)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Paper.badge, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                        }
                                    }
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 12)

                                if idx != convs.count - 1 { PaperDashLine() }
                            }
                        }
                    }
                    .padding(.top, 8)

                    Spacer().frame(height: 96)
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
            }

            PaperTabBar(
                items: [("◌", "会话"), ("✦", "发现"), ("☰", "联系人"), ("☺", "我的")],
                active: $tab
            )
            .padding(.bottom, 14)
        }
    }

    private func friend(_ name: String, _ affinity: Int) -> some View {
        VStack(spacing: 4) {
            PaperAvatar(name: name, size: 52)
            Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(Paper.ink)
            Text("好感 \(affinity)").font(.system(size: 9.5)).foregroundColor(Paper.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// ---------------------------------------------------------------- 商城
private struct PaperPlan: Identifiable {
    let id = UUID()
    let name: String
    let price: Int?
    let note: String
    var hot = false
    var off = false
}

struct PaperShopView: View {
    var onBack: () -> Void = {}

    private let plans = [
        PaperPlan(name: "免费", price: 0, note: "每周 100 积分 · 每天签到再领 10–15"),
        PaperPlan(name: "Go", price: 15, note: "每周 500 积分 · 免费 ×5"),
        PaperPlan(name: "Plus", price: 26, note: "每周 1,200 积分 · 免费 ×12", hot: true),
        PaperPlan(name: "Pro", price: 78, note: "每周 3,600 积分 · Plus ×3"),
        PaperPlan(name: "Pro Max", price: 108, note: "每周 6,000 积分 · Plus ×5"),
        PaperPlan(name: "畅聊", price: nil, note: "不计积分，随便聊", off: true)
    ]

    private let reset = [("Go 用户（你现在）", "¥3.75"), ("Plus 用户", "¥6.5"),
                         ("Pro 用户", "¥19.5"), ("Pro Max 用户", "¥27")]

    var body: some View {
        ZStack {
            Paper.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 9) {
                    HStack(spacing: 10) {
                        PaperIconButton(glyph: "‹", action: onBack)
                        Text("商城").font(.system(size: 17, weight: .semibold)).foregroundColor(Paper.ink)
                        Spacer()
                    }
                    .padding(.bottom, 6)

                    ForEach(plans) { p in
                        planRow(p)
                    }

                    PaperGroupLabel(text: "重置卡 · 套餐价 ÷ 4").padding(.top, 14)

                    PaperCard {
                        VStack(spacing: 0) {
                            ForEach(Array(reset.enumerated()), id: \.offset) { i, item in
                                HStack {
                                    Text(item.0).font(.system(size: 11.5)).foregroundColor(Paper.inkSub)
                                    Spacer()
                                    Text(item.1).font(.system(size: 12, weight: .semibold)).foregroundColor(Paper.ink)
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                if i != reset.count - 1 { PaperDashLine() }
                            }
                        }
                    }

                    Text("用完本周额度才需要重置；重置后发放日不变，本周仍然只发一次。")
                        .font(.system(size: 10.5))
                        .foregroundColor(Paper.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, 16)
                .padding(.top, 52)
            }
        }
    }

    private func planRow(_ p: PaperPlan) -> some View {
        PaperCard(radius: PaperRadius.lg, shadow: 2.5) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(p.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(p.off ? Paper.inkMuted : Paper.ink)
                        if p.hot {
                            Text("热门")
                                .font(.system(size: 9))
                                .foregroundColor(Paper.onAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Paper.accent, in: RoundedRectangle(cornerRadius: 4))
                        }
                        if p.off {
                            Text("暂不开")
                                .font(.system(size: 9))
                                .foregroundColor(Paper.onAccent)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Paper.lineStrong, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    Text(p.note)
                        .font(.system(size: 10.5))
                        .foregroundColor(Paper.inkSub)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(p.price == nil ? "—" : "¥\(p.price!)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(p.off ? Paper.inkMuted : Paper.ink)
                    Text(p.price == 0 ? "永久" : "/ 月")
                        .font(.system(size: 10))
                        .foregroundColor(Paper.inkMuted)
                }
            }
            .padding(13)
        }
        .overlay(
            RoundedRectangle(cornerRadius: PaperRadius.lg, style: .continuous)
                .strokeBorder(p.hot ? Paper.accent : Color.clear, lineWidth: 2)
        )
    }
}
