import SwiftUI

/// 她自己拨过来时，从顶上滑进来的那一张「来电卡」。
///
/// ## 用户 2026-10-01 要的
/// 「当有主动来电时，先将 APP 推到主界面，然后他再来电，APP 自动退出。」
/// 还有上一版那句：「你要让他真的能动起来，不要让他只是这么说而已。」
///
/// ## 为什么做成这个样子
///
/// 他真正想要的形态是**苹果那种来电**：App 退到后台，灵动岛上响。
/// 但 iOS 上「App 自己退回主界面」这件事**没有公开 API**（能做的只有
/// `ShortcutBridge.goHome()` 那条系统内部选择器，不敢用在"打电话"这条路上 ——
/// 万一系统把它摘了，用户点"接听"会卡在原地，比不做还糟）。
///
/// 所以这里退一步，做一个**在系统允许范围内最像来电**的东西：
/// 悬在整个界面上方的一张卡，有头像、有名字、有她的话，两个按钮「接听 / 先不了」。
/// 接通之后走的是和别处**完全一样**的那条路（`AppRouter.startCall()` →
/// `CallService.start()` → 苹果的 `LiveCommunicationKit` 界面）。
///
/// 换句话说：这一段补上的是"她**能**打过来"这件事本身。
/// 以前 `ask_to_call` 那条工具是发得出来的，但 `CompanionRequestBar` 那张小条
/// 夹在聊天页顶上，一翻页就看不见了 —— 一条会响的来电通知还得靠 `callEnabled`
/// （默认关）才有。所以她其实**几乎从没**真的打过来过。这张卡把它变成了真的。
///
/// ## 为什么不用 `.alert`
/// `.alert` 是系统样式，长得像"权限申请"，不像"有人在给你打电话"。
/// 而且系统弹窗会吃掉背景手势，用户想边看边决定都做不到。
struct IncomingCallCard: View {

    /// 她打过来时说的那句话（`CompanionRequest.Item.reason`）。
    let reason: String
    /// 打给谁 —— 用当前联系人，跟通话页里那个名字是同一个来源。
    let persona: Persona
    let onAccept: () -> Void
    let onDecline: () -> Void

    @ObservedObject private var settings = AppSettings.shared

    /// 头像外面那一圈呼吸的光。进来就开始动 —— 「会响的来电」和
    /// 「一条静止的提示」差别就在这里。
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 14) {
            header
            if !reason.isEmpty {
                Text("「\(reason)」")
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            buttons
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.22), radius: 24, y: 8)
        )
        .padding(.horizontal, 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    // MARK: - 上半：头像 + 名字 + 状态

    private var header: some View {
        HStack(spacing: 13) {
            AevisAvatar(source: .ai, size: 54, seed: persona.avatarSeed)
                .overlay(
                    Circle()
                        .strokeBorder(
                            settings.accentColor.opacity(breathing ? 0.9 : 0.25),
                            lineWidth: 2.5
                        )
                        .scaleEffect(breathing ? 1.08 : 1.0)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(persona.name.isEmpty ? "TA" : persona.name)
                    .font(.aevis(17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: "phone.arrow.down.left.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("想给你打个电话")
                        .font(.aevis(12.5))
                }
                .foregroundStyle(settings.accentColor)
            }

            Spacer(minLength: 4)
        }
    }

    // MARK: - 下半：接 / 不接

    private var buttons: some View {
        HStack(spacing: 11) {
            Button(action: onDecline) {
                Text("先不了")
                    .font(.aevis(14.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            Button(action: onAccept) {
                HStack(spacing: 6) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("接听")
                        .font(.aevis(14.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.green)
                )
            }
            .buttonStyle(.plain)
        }
    }
}
