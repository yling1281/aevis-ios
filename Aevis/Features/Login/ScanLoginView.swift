import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「用手机扫码登录」—— **新设备这一侧**（2026-10-03）。
///
/// 老板原话：「如果检测到登录的设备是 iPad，支持手机扫码登录，扫码后就直接同步。」
///
/// ## 屏幕上发生的事
/// 这个页面拿一张票 → 把它画成二维码 → 每两秒问服务器一句「有人批了吗」。
/// 用户拿**手机**（随便什么相机 App）扫这张码，会打开
/// `https://account.aevis.cn/scan?t=…`；那一页上点一下「同意」，
/// 这边下一次轮询就拿到登录态了 —— **用户不用在这台设备上敲任何字**。
///
/// ## 为什么不用自定义 scheme（`aevis://…`）
/// 因为扫它的**不一定是 Aevis** —— 系统相机根本不把 `aevis://` 认成链接。
/// 用普通 https 网址，任何手机都能扫开。服务端那一页见
/// `server/account/web/scan.html`。
///
/// ## 🔴 安全边界（页面可以被人随便看、随便拍）
/// 二维码里**只有一张票**，不包含任何账号信息。拿到票最多能做到"请某个人来批一下"，
/// 而"批"这个动作**必须由一个已经登录的手机点**（服务器 `api_device_login_approve`
/// 走 `current_user()` 鉴权）。票**5 分钟**过期、**一次性**用完即废。
/// ⇒ 所以这个页面被同事瞄到、被摄像头拍到，都不构成"账号泄露"。
///
/// ## ⚠️ 这里**不**负责同步聊天记录
/// 「扫码后就直接同步」是这么接上的：这里把登录态装上之后，
/// `RootView` 盯着的 `account.isSignedIn` 变了 ⇒ 触发
/// `AutoSync.autoRestoreIfNewDevice()`（本机还是空的话，从百度网盘把记录拉回来）。
/// **不要在下面自己再调一次恢复** —— 那会变成两条路同时恢复同一份数据。
struct ScanLoginView: View {

    /// 登录成功之后要做什么（`LoginView` 传进来，一般是关掉这个页面）。
    var onDone: () -> Void

    @ObservedObject private var account = AccountService.shared

    /// 换一张二维码就 +1 —— 它是下面那个 `.task(id:)` 的钥匙：
    /// SwiftUI 会因为 id 变了而**取消旧的轮询、重跑一遍**（自动的，不用手动取消）。
    @State private var nonce = 0

    @State private var ticket = ""
    @State private var expiresAt = Date.distantFuture
    @State private var qr: UIImage?
    /// 出问题了（生成不出来 / 过期 / 被别处用掉），非空就把二维码换成这句话。
    @State private var dead: String?
    @State private var starting = true

    var body: some View {
        ZStack {
            // 扫码登录页同样属于「开始页」这条链路（门禁 → 登录/扫码 → 主界面），
            // 背景跟 RootView 的 `.start` 一致，避免页面间背景跳变。
            AevisBackground(scope: .start)

            ScrollView {
                VStack(spacing: 16) {
                    header
                    codeCard
                    steps
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.never)
        }
        // ⚠️ 用 `.task(id: nonce)` 而不是在 `onAppear` 里起一个 Task：
        //    这样**页面消失时 SwiftUI 会自动取消轮询**（不用手写取消逻辑），
        //    也不会出现"退出去了还在后台每两秒打服务器"。
        .task(id: nonce) { await run() }
    }

    // MARK: - 头

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)

            Text("用手机扫码登录")
                .font(.aevis(21, weight: .semibold))
                .foregroundStyle(.primary)

            Text("不用在这台设备上敲邮箱和验证码。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 二维码

    @ViewBuilder
    private var codeCard: some View {
        VStack(spacing: 14) {
            if let dead {
                // —— 出问题了：把二维码换掉，别留一张已经作废的码在上面 ——
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(dead)
                    .font(.aevis(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if starting || qr == nil {
                ProgressView()
                    .tint(.secondary)
                Text("正在生成二维码…")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            } else if let qr {
                Image(uiImage: qr)
                    .interpolation(.none)          // 二维码**必须**关掉插值，糊了就扫不出来
                    .resizable()
                    .scaledToFit()
                    .frame(width: 236, height: 236)
                    .padding(10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                countdown
            }

            Button(dead == nil ? "换一张" : "重新生成") {
                nonce += 1
            }
            .font(.aevis(13, weight: .medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 18)
        .aevisGlass(cornerRadius: 20)
    }

    /// 倒计时。用 `TimelineView` 每秒自己重画一次 —— 不用再养一个 `Timer`，
    /// 页面走了它自己就停了（`Timer` 还得记得 invalidate，忘了就是后台常驻）。
    @ViewBuilder
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded()))
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 11))
                Text(left > 0 ? "还有 \(left / 60):\(String(format: "%02d", left % 60))"
                              : "已经过期了")
                    .font(.aevis(12))
            }
            .foregroundStyle(left > 30 ? Color.secondary : Color.orange)
        }
    }

    // MARK: - 三步说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ⚠️ 加粗那段**必须**在调用点就包成 `Text(LocalizedStringKey(…))`。
            //    写成 `line("1", "拿你**…**，…")` 的话，星号会在界面上一字不差地
            //    显示出来（`Text(String)` 不解析 markdown），R17 也是这么判的。
            line("1", Text(LocalizedStringKey("拿你**已经登录过 Aevis 的那台手机**，用相机扫上面这张码。")))
            line("2", Text(LocalizedStringKey("手机会打开一个网页，上面点一下「同意登录」。")))
            line("3", Text(LocalizedStringKey("这边会自己登上，聊天记录接着从百度网盘同步过来。")))
        }
        .padding(18)
        .aevisGlass(cornerRadius: 18)
    }

    /// ⚠️ 参数收的是 `Text` 而不是 `String` —— 这样"要解析 markdown"这件事
    ///    在**调用点**就说清楚了（见上面 `steps` 的注释），helper 只负责排版。
    private func line(_ number: String, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.aevis(11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
            text
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 真正的活

    /// 生成一张码 → 一直问到有人批 / 过期 / 出错。
    private func run() async {
        starting = true
        dead = nil
        qr = nil
        ticket = ""

        let fresh: AccountService.DeviceTicket
        do {
            fresh = try await account.newDeviceLoginTicket()
        } catch {
            starting = false
            dead = "二维码生成不出来：" + error.localizedDescription
            return
        }
        if Task.isCancelled { return }      // 生成期间用户已经走了

        ticket = fresh.ticket
        expiresAt = Date().addingTimeInterval(TimeInterval(fresh.expiresIn))
        qr = ConfigShare.image(for: fresh.scanURL, scale: 10)
        starting = false

        while !Task.isCancelled {
            if Date() >= expiresAt {
                dead = "二维码过期了，点下面重新生成一张。"
                return
            }
            do {
                let status = try await account.pollDeviceLogin(ticket: ticket)
                if case .approved(let email, let token) = status {
                    // 服务器认过了 —— 装上登录态。`adoptWebToken` 会顺手拉一次资料，
                    // 失败会抛（比如 token 恰好被人抢先用了），那种情况退回"重新生成"。
                    do {
                        try await account.adoptWebToken(token)
                    } catch {
                        dead = "登录态没装上：" + error.localizedDescription
                        return
                    }
                    BlackBox.log("扫码登录成功：\(email)")
                    onDone()
                    return
                }
            } catch let problem as DeviceLoginError {
                // 过期 / 用过 / 不认 —— 这三种**必须停下来**，接着轮询只是白打服务器。
                // 409（已经批过）有点微妙：说明流程其实走通了，只是我们没拿到 token
                // （多半是"手机点完同意，这台设备却已经轮询超时"）。文案照实说，
                // 用户重来一次即可。
                dead = problem.errorDescription
                return
            } catch {
                // ⚠️ **网络抖一下必须当没事**。这是每两秒一次的轮询，
                //    把一次超时当成失败结束流程，等于用户在地铁里扫一半就前功尽弃。
                //    接着问，问到期自然会有个结果。
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}
