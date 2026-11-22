import SwiftUI
import UIKit
import WebKit
import AuthenticationServices

/// 登录页（2026-11-22 明亮版 —— 仿安卓 / 小程序）。
///
/// 视觉：奶油底 #FFF8EC + 柔紫 #9B8AF0，自绘矢量狗 `AevisMascot` 做品牌图标；
/// 不再有深蓝黑渐变头图，不再有 ScrollView（登录内容一屏放下，小屏自动收紧）。
///
/// 规矩（功能一点没动）：
///   · 未勾协议点按钮 → 提示「请先阅读并同意用户协议和隐私政策。」（真的拦住提交）；
///   · 微信 / QQ 需要真实授权，点了只给明确提示，**绝不假装登录成功**；
///   · QQ 走 `ASWebAuthenticationSession` 跳系统浏览器，服务端 302 回 `aevis://login?token=…`；
///   · 扫码走 `/v1/auth/wx/qr/create` + `/poll`，二维码用 CoreImage 现画（不引第三方库）。
///   · 所有登录方式统一走 `session.applyLogin(token:email:)`：先落本地登录态，再静默恢复云端聊天记录。
struct LoginView: View {
    @EnvironmentObject private var session: Session

    enum Mode { case code, password }
    @State private var mode: Mode = .code
    @State private var register = false

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var agree = false
    @State private var busy = false
    @State private var tip = ""

    @State private var showRecover = false
    @State private var showQR = false
    @State private var showLines = false
    @State private var qqSheet = false
    @State private var wxQR: APIClient.WXQR? = nil
    @FocusState private var focused: Field?
    enum Field { case email, password, code }

    private var canSubmit: Bool {
        guard agree, !busy else { return false }
        if mode == .code { return email.contains("@") && code.count == 6 }
        return email.contains("@") && password.count >= 8
    }

    private var buttonTitle: String {
        if register { return "注册并登录" }
        return mode == .code ? "验证并登录" : "登录"
    }

    var body: some View {
        // 一屏布局：GeometryReader 量可用高度，矮屏（iPhone SE）收紧留白/字号，
        // 绝不用 ScrollView —— 登录页不允许上下滚动。
        GeometryReader { geo in
            let compact = geo.size.height < 700

            ZStack(alignment: .top) {
                AE.brandCream.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focused = nil }

                // 顶部柔光装饰（纯视觉，不拦截点击；对齐官网 logo 的柔紫/暖橙光晕）
                ZStack(alignment: .topTrailing) {
                    Circle().fill(AE.brandLilac.opacity(0.55))
                        .frame(width: 220, height: 220).blur(radius: 40)
                        .offset(x: 52, y: -80)
                    Circle().fill(AE.brandPeach.opacity(0.30))
                        .frame(width: 150, height: 150).blur(radius: 36)
                        .offset(x: -128, y: 132)
                }
                .frame(width: geo.size.width, height: 320)
                .clipped()
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    hero(compact: compact)
                        .padding(.top, compact ? 6 : 14)
                    formCard
                        .padding(.top, compact ? 12 : 18)
                    if !tip.isEmpty { tipBanner.padding(.top, 10) }
                    submitButton
                        .padding(.top, compact ? 10 : 14)
                    agreementRow
                        .padding(.top, compact ? 9 : 12)
                    Spacer(minLength: 8)
                    sectionLabel("其他登录方式")
                    thirdPartyRow
                        .padding(.top, compact ? 8 : 12)
                    noteText
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, compact ? 20 : 24)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
        .background(AE.brandCream.ignoresSafeArea())
        .sheet(isPresented: $showRecover) { RecoverView() }
        .sheet(isPresented: $showLines) { LineSheet() }
        .sheet(isPresented: $qqSheet) {
            QQSheet { token in
                qqSheet = false
                Task { await session.applyLogin(token: token, email: email) }
            }
        }
        .sheet(item: Binding(
            get: { wxQR.map { WXItem(info: $0) } },
            set: { if $0 == nil { wxQR = nil } }
        )) { item in
            WxQRView(info: item.info) { token in
                wxQR = nil
                Task { await session.applyLogin(token: token, email: email) }
            }
        }
    }

    // MARK: - 顶部视觉区（不再写死 316，随可用高度收缩）

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer()
            // 线路入口（未登录也能用），只显示城市名，不显示地址
            Button { showLines = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 12))
                    Text("线路 · " + APIClient.activeLine.name)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(AE.brandInk.opacity(0.72))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(AE.brandCard.opacity(0.75))
                .clipShape(Capsule())
            }
            Button("帮助") { tip = "如需帮助，请联系 aevis.cn 客服。" }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AE.brandInk.opacity(0.72))
        }
    }

    private func hero(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            appIcon(compact: compact)
            VStack(alignment: .leading, spacing: 5) {
                Text("登录发现更多精彩")
                    .font(.system(size: compact ? 23 : 27, weight: .bold, design: .rounded))
                    .foregroundStyle(AE.brandInk)
                    .minimumScaleFactor(0.85)
                    .lineLimit(1)
                Text("验证码只发给已注册的邮箱；还没有账号就点「去注册」。")
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 自家矢量狗 logo（官网 icon-new.svg 的 Path 重绘），不再用 SF Symbol dog.fill
    private func appIcon(compact: Bool) -> some View {
        AevisMascot(size: compact ? 60 : 76)
            .shadow(color: AE.brandPurple.opacity(0.20), radius: 14, x: 0, y: 6)
    }

    // MARK: - 表单卡

    private var formCard: some View {
        VStack(spacing: 10) {
            emailField
            if mode == .password || register { passwordField }
            if mode == .code || register { codeRow }
            switchRow
        }
        .padding(14)
        .background(AE.brandCard)
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous))
        .shadow(color: AE.brandPurple.opacity(0.08), radius: 12, y: 4)
    }

    private var fieldBG: Color { AE.brandWell }

    private var emailField: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AE.brandPurple.opacity(0.8))
                .frame(width: 20)
            TextField("请输入邮箱", text: $email)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AE.brandPurple.opacity(0.8))
                .frame(width: 20)
            SecureField("密码：至少 8 位，含字母和数字", text: $password)
                .font(.system(size: 15))
                .focused($focused, equals: .password)
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var codeRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "number")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AE.brandPurple.opacity(0.8))
                    .frame(width: 20)
                TextField("邮箱里那 6 位数字", text: $code)
                    .font(.system(size: 15))
                    .keyboardType(.numberPad)
                    .focused($focused, equals: .code)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .background(fieldBG)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button { Task { await sendCode() } } label: {
                Text(busy ? "发送中" : "发送验证码")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AE.brandPurple)
                    .frame(width: 88, height: 50)
                    .background(AE.brandLilac)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .disabled(busy || !email.contains("@"))
            .opacity(busy || !email.contains("@") ? 0.55 : 1)
            .buttonStyle(AevisPressStyle(scale: 0.96))
        }
    }

    private var switchRow: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mode = (mode == .code) ? .password : .code
                    tip = ""
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right.circle")
                        .font(.system(size: 14))
                    Text(mode == .code ? "密码登录" : "验证码登录")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(AE.brandPurple)
            }
            Spacer()
            Button(register ? "已经有账号，去登录" : "没有账号，去注册") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    register.toggle()
                    tip = ""
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(AE.textSecondary)
        }
        .padding(.top, 2)
    }

    // MARK: - 提交 / 协议

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(canSubmit ? AE.brandPurple : AE.brandPurple.opacity(0.35))
            .clipShape(Capsule())
            .shadow(color: canSubmit ? AE.brandPurple.opacity(0.26) : .clear, radius: 12, y: 6)
        }
        // 只按 busy 禁用：保留 submit() 里「未勾协议」的拦截提示
        .disabled(busy)
        .buttonStyle(AevisPressStyle(scale: 0.975))
    }

    private var tipBanner: some View {
        let isGood = tip.contains("已发送") || tip.contains("成功")
        return HStack(spacing: 8) {
            Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
            Text(tip)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isGood ? AE.brandPurple : Color.hex(0xE5484D))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AE.brandLilac.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var agreementRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { agree.toggle() }
            } label: {
                ZStack {
                    if agree {
                        Circle().fill(AE.brandPurple).frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Circle().stroke(AE.brandInk.opacity(0.28), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意用户协议和隐私政策")

            HStack(spacing: 0) {
                Text("已阅读并同意 ").foregroundStyle(AE.textSecondary)
                Link("用户协议", destination: URL(string: "https://aevis.cn/terms.html")!)
                    .foregroundStyle(AE.brandPurple)
                Text(" 和 ").foregroundStyle(AE.textSecondary)
                Link("隐私政策", destination: URL(string: "https://aevis.cn/privacy.html")!)
                    .foregroundStyle(AE.brandPurple)
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noteText: some View {
        Text("未注册的邮箱验证通过后将自动创建账号。")
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(separator).frame(height: 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(AE.textSecondary)
            Rectangle().fill(separator).frame(height: 1)
        }
        .padding(.top, 4)
    }

    private var separator: Color {
        Color.adaptive(dark: Color.white.opacity(0.12), light: Color.hex(0xEDE6D9))
    }

    // MARK: - 第三方登录

    private var thirdPartyRow: some View {
        HStack(alignment: .center, spacing: 16) {
            circleButton(icon: "message.fill", label: "微信", tint: Color.hex(0x4AB85C)) {
                Task { await startWeChat() }
            }
            circleButton(icon: "bubble.left.fill", label: "QQ", tint: Color.hex(0x428CF0)) {
                qqSheet = true
            }
            circleButton(icon: "qrcode", label: "扫码", tint: AE.brandPurple) {
                showQR = true
            }
            Spacer(minLength: 0)
            Button { showRecover = true } label: {
                Text("找回账号")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AE.brandPurple)
                    .underline(true, color: AE.brandPurple.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
    }

    private func circleButton(
        icon: String, label: String, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                ZStack {
                    Circle().fill(AE.brandCard).frame(width: 52, height: 52)
                    Circle().stroke(separator, lineWidth: 1).frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(tint)
                }
                .shadow(color: AE.shadowColor, radius: 6, y: 3)
            }
            .buttonStyle(AevisPressStyle(scale: 0.94))
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)
        }
    }

    // MARK: - 行为

    /// 唤起小程序 + 轮询；唤起失败就退回二维码
    private func startWeChat() async {
        do {
            let info = try await APIClient.wxQRCreate()
            // 优先唤起微信小程序（服务端给的 jump_url）
            var opened = false
            if let u = URL(string: info.jumpURL) {
                opened = await UIApplication.shared.open(u)
            }
            NSLog(opened ? "open weixin://dl/business/..." : "wechat open failed, fallback qr")
            if !opened { wxQR = info }
            // 无论哪种方式都轮询（小程序里确认后服务端会给 token）
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                if let token = (try? await APIClient.wxQRPoll(ticket: info.ticket)) ?? nil {
                    await session.applyLogin(token: token, email: email)
                    wxQR = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            tip = opened ? "等待确认超时，请重试" : "二维码已过期，请重试"
        } catch {
            tip = "微信登录失败：\(error.localizedDescription)"
        }
    }

    private func sendCode() async {
        tip = ""
        busy = true
        do {
            try await APIClient.sendEmailCode(email: email)
            tip = "验证码已发送"
        } catch {
            tip = friendly(error)
        }
        busy = false
    }

    private func submit() async {
        guard agree else {
            tip = "请先阅读并同意用户协议和隐私政策。"
            return
        }
        tip = ""
        busy = true
        do {
            let r: APIClient.LoginResult
            if register {
                r = try await APIClient.register(email: email, password: password, code: code)
            } else if mode == .code {
                r = try await APIClient.loginByCode(email: email, code: code)
            } else {
                r = try await APIClient.login(email: email, password: password)
            }
            await session.applyLogin(token: r.token, email: email)
        } catch {
            tip = friendly(error)
        }
        busy = false
    }

    private func friendly(_ e: Error) -> String {
        let m = e.localizedDescription
        if m.contains("验证码") { return "验证码不正确" }
        if m.isEmpty { return "操作失败，请稍后再试" }
        return m
    }
}

// MARK: - 通用组件（本文件内两个文件共用，internal 供 SettingsView 复用）

/// 按压回弹：比系统默认高亮更克制，iOS 16 可用（不依赖新 API）。
struct AevisPressStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// 只圆下方两角：iOS 16 没有 UnevenRoundedRectangle，用 UIBezierPath 画一个。
private struct BottomRoundedShape: Shape {
    var radius: CGFloat = 36
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                 radius: radius)
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius),
                 radius: radius)
        p.closeSubpath()
        return p
    }
}

// MARK: - 找回账号

struct RecoverView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var tip = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("找回账号").font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(AE.brandInk)
            Text("输入注册邮箱，我们会发送一条验证码；验证通过后可重设密码。")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
            TextField("注册邮箱", text: $email)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            if !tip.isEmpty {
                Text(tip).font(.system(size: 12)).foregroundStyle(AE.textSecondary)
            }
            Button {
                Task {
                    busy = true
                    do {
                        try await APIClient.sendEmailCode(email: email)
                        tip = "验证码已发送"
                    } catch {
                        tip = error.localizedDescription
                    }
                    busy = false
                }
            } label: {
                Text(busy ? "发送中" : "发送验证码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(AE.brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
            }
            .disabled(busy || !email.contains("@"))
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

// MARK: - 扫码登录（服务端给 image_url，微信唤不起时用它兜底）

/// SwiftUI 的 `.sheet(item:)` 需要一个 Identifiable 包装
struct WXItem: Identifiable {
    let id = UUID()
    let info: APIClient.WXQR
}

struct WxQRView: View {
    @Environment(\.dismiss) private var dismiss
    let info: APIClient.WXQR
    var onToken: (String) -> Void

    @State private var tip = "等待微信里确认…（最长 180 秒）"
    @State private var cancelled = false

    private var imageURL: URL? {
        guard !info.imageURL.isEmpty else { return nil }
        if info.imageURL.hasPrefix("http") { return URL(string: info.imageURL) }
        return URL(string: APIClient.base + info.imageURL)
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("用微信扫码登录").font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(AE.brandInk)
            Text("也可以点下方按钮打开微信，再扫这张码")
                .font(.system(size: 12)).foregroundStyle(AE.textSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(fieldBGForQR).frame(width: 240, height: 240)
                if let u = imageURL {
                    AsyncImage(url: u) { img in
                        img.resizable().interpolation(.none).scaledToFit()
                    } placeholder: { ProgressView() }
                    .frame(width: 208, height: 208)
                } else {
                    ProgressView()
                }
            }

            Text(tip).font(.system(size: 12)).foregroundStyle(AE.textSecondary)

            Button {
                if let u = URL(string: "weixin://"), UIApplication.shared.canOpenURL(u) {
                    UIApplication.shared.open(u)
                } else {
                    tip = "未安装微信"
                }
            } label: {
                Text("打开微信")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(AE.brandPurple)
                    .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
            }

            Button("取消") {
                cancelled = true
                dismiss()
            }
            .foregroundStyle(AE.textSecondary)

            Spacer()
        }
        .padding(24)
        .presentationDetents([.large])
        .task { await poll() }
    }

    private var fieldBGForQR: Color { AE.brandWell }

    private func poll() async {
        let deadline = Date().addingTimeInterval(180)
        while !cancelled && Date() < deadline {
            if let token = (try? await APIClient.wxQRPoll(ticket: info.ticket)) ?? nil {
                tip = "登录成功"
                onToken(token)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if !cancelled { tip = "二维码已过期，请重试" }
    }
}

// MARK: - QQ 登录：系统浏览器（ASWebAuthenticationSession）

/// 提供系统浏览器弹出所需的 window anchor。
private final class QQAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

/// QQ 授权走系统 Safari（官方浏览器引擎 + 共享 cookie），
/// 服务端 `/v1/auth/qq/callback` 把 code 换 token 后 302 到 `aevis://login?token=…`，
/// 回调里直接解析 token 登录，不再用内嵌 WKWebView。
struct QQSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onToken: (String) -> Void

    @State private var tip = "正在获取授权地址…"
    /// 强引用持有 session，否则发起后立刻被释放
    @State private var authSession: ASWebAuthenticationSession?
    @State private var presenter = QQAuthPresenter()

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(AE.brandLilac).frame(width: 60, height: 60)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.hex(0x428CF0))
            }
            Text("QQ 登录")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(AE.brandInk)
            Text("将打开系统浏览器完成 QQ 授权，完成后自动回到 Aevis。")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .multilineTextAlignment(.center)
            if !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("取消") { dismiss() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AE.brandPurple)
        }
        .padding(24)
        .presentationDetents([.medium])
        .task { await start() }
        .onDisappear {
            authSession?.cancel()
            authSession = nil
        }
    }

    private func start() async {
        do {
            let auth = try await APIClient.qqAuthURL()
            guard !auth.url.isEmpty, let url = URL(string: auth.url) else {
                tip = "QQ 授权地址无效，请稍后重试"
                return
            }
            await MainActor.run {
                tip = "正在打开系统浏览器…"
                let s = ASWebAuthenticationSession(url: url, callbackURLScheme: "aevis") { callbackURL, error in
                    if let error = error {
                        let msg = error.localizedDescription
                        Task { @MainActor in
                            tip = "QQ 授权未完成：\(msg)。若提示无法打开，请确认 App 已注册 aevis 回调地址。"
                        }
                        return
                    }
                    guard let cb = callbackURL,
                          let token = URLComponents(url: cb, resolvingAgainstBaseURL: false)?
                              .queryItems?.first(where: { $0.name == "token" })?.value,
                          !token.isEmpty else {
                        Task { @MainActor in tip = "QQ 登录回调缺少 token，请重试" }
                        return
                    }
                    Task { @MainActor in
                        tip = "QQ 登录成功"
                        dismiss()
                        onToken(token)
                    }
                }
                // false = 复用系统 Safari 的 cookie（真正的「官方浏览器」），不是无痕会话
                s.prefersEphemeralWebBrowserSession = false
                s.presentationContextProvider = presenter
                authSession = s
                if !s.start() {
                    tip = "无法打开系统浏览器，请检查 aevis:// 回调地址是否已注册。"
                }
            }
        } catch {
            tip = "QQ 授权失败：\(error.localizedDescription)"
        }
    }
}

/// 历史遗留：旧版内嵌 WKWebView 授权（已被 `ASWebAuthenticationSession` 取代，
/// 保留定义只为兼容可能的外部引用，登录入口不再使用它）。
struct QQWebView: UIViewRepresentable {
    let urlString: String
    let callbackPrefix: String
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        if let u = URL(string: urlString) {
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: QQWebView
        private var fired = false
        init(_ p: QQWebView) { parent = p }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               url.absoluteString.hasPrefix(parent.callbackPrefix) {
                NSLog("decidePolicy callback: \(url.absoluteString)")
                if !fired,
                   let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
                   !code.isEmpty {
                    fired = true
                    parent.onCode(code)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - 线路选择（只显示城市名，不显示任何地址）

struct LineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var active: String = APIClient.activeLine.id
    @State private var lineTip = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(APIClient.lines) { line in
                        Button {
                            // 坏线路（base 空 = 实测 404 / 自签 SSL）不让选中，给明确提示
                            guard !line.base.isEmpty else {
                                let why = line.note.isEmpty ? "请切换其它线路" : line.note
                                lineTip = "「\(line.name)」线路暂不可用：\(why)"
                                return
                            }
                            lineTip = ""
                            APIClient.setActiveLine(line.id)
                            active = line.id
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(line.name).font(.system(size: 16, weight: .medium))
                                    if !line.note.isEmpty {
                                        Text(line.note).font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if line.base.isEmpty {
                                    Text("暂不可用").font(.system(size: 12)).foregroundStyle(.secondary)
                                } else if active == line.id {
                                    Image(systemName: "checkmark").foregroundStyle(AE.brandPurple)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("连不上会自动重试其它线路")
                        .font(.system(size: 11))
                }

                if !lineTip.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 13))
                            Text(lineTip).font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(Color.hex(0xE5484D))
                    }
                }
            }
            .navigationTitle("线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
