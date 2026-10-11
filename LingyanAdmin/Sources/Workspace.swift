import Foundation

/// 这个 App 里能进的**两个后台**。
///
/// 零砚 2026-10-11 原话：「素材管理器后台做过了，把那个更新一下，拥有一个完整的后台，
/// 然后把两个合并到一起」——所以**一个 App 装两个后台**，顶上一根切换条分家。
///
/// 两边**各有各的服务器地址、各有各的登录态**，互不影响：
/// 码支付那边退出登录 / 令牌过期，不会把素材后台也踢出去（反之亦然）。
/// 为什么不合成一个登录态：它们压根是两套账号体系（见 PayConfig 顶部注释）。
enum Workspace: String, CaseIterable, Identifiable {
    case sucai
    case pay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sucai: return "素材后台"
        case .pay: return "码支付"
        }
    }

    var icon: String {
        switch self {
        case .sucai: return "square.stack.3d.up.fill"
        case .pay: return "qrcode"
        }
    }

    /// 截图自检 / 想直接开在某一边用：`-ws pay`。
    ///
    /// ⚠️ 这里**不能**写 `Workspace.allCases` —— 本地静态自检
    ///    （`_ios/check_swift.py` 第 5 条）会把它判成「Workspace 里没这个成员」，
    ///    因为 `allCases` 是 CaseIterable 合成的、不在类型体里。
    ///    要用循环就手写数组（见 WorkspaceBar）。
    static var initial: Workspace {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-ws"), i + 1 < args.count {
            return args[i + 1].lowercased() == "pay" ? .pay : .sucai
        }
        if AppConfig.shared.configured { return .sucai }
        if PayConfig.shared.configured { return .pay }
        return .sucai
    }
}

/// 顶上那根「切后台」的条。
///
/// ⚠️ 为什么自己画一根、不用 `TabView`：
///    素材后台已经占了 5 个页签（iOS 的 TabView 超过 5 个会自己冒出一个英文
///    「More」页签，跟中文界面对不上），两个后台再合起来就是 10 个 —— 不可能。
///    所以「后台」这一层用顶部条，「页签」那一层留给各自的 TabView。
struct WorkspaceBar: View {
    @Binding var ws: Workspace
    @ObservedObject private var cfg = AppConfig.shared
    @ObservedObject private var pay = PayConfig.shared

    private var loggedIn: Bool {
        ws == .sucai ? cfg.configured : pay.configured
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach([Workspace.sucai, Workspace.pay]) { w in
                Button {
                    ws = w
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: w.icon).font(.caption2)
                        Text(w.title).font(.footnote.weight(ws == w ? .semibold : .regular))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(ws == w ? Color.accentColor.opacity(0.16) : Color.clear,
                                in: Capsule())
                    .foregroundStyle(ws == w ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            Circle()
                .fill(loggedIn ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(loggedIn ? "已登录" : "未登录")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(UIColor.secondarySystemBackground))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(Color(UIColor.separator)),
            alignment: .bottom
        )
    }
}
