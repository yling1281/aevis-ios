import SwiftUI
import UIKit
import WebKit

/// 登录页（2026-11-22 视觉重做）。
///
/// 结构从上到下（间距按 8 的倍数）：
///   渐变头图（线路/帮助 + dog 图标 + 大标题）→ 表单卡（邮箱/验证码/密码/切换）
///   → 实色主按钮 → 协议 → 提示 → 「其他登录方式」→ 微信/QQ/扫码 + 找回账号
///
/// 规矩（功能一点没动）：
///   · 未勾协议点按钮 → 提示「请先阅读并同意用户协议和隐私政策。」（真的拦住提交）；
///   · 微信 / QQ 需要 AppID，点了只给明确提示，**绝不假装登录成功**；
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
        ZStack {
            Color.paper.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero

                    VStack(alignment: .leading, spacing: 20) {
                        formCard

                        if !tip.isEmpty { tipBanner }

                        submitButton
                        agreementRow
                        noteText
                        sectionLabel("其他登录方式")
                        thirdPartyRow
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = nil }
        }
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

    // MARK: - 顶部视觉区

    private var hero: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color.hex(0x232C42), AE.accentDeep, Color.hex(0x3D4A69)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // 柔光斑：低透明度 + 模糊，给渐变加层次
            Circle().fill(Color.white.opacity(0.09))
                .frame(width: 240, height: 240).blur(radius: 36)
                .offset(x: -118, y: -72)
            Circle().fill(AE.accentLift.opacity(0.55))
                .frame(width: 150, height: 150).blur(radius: 30)
                .offset(x: 132, y: 56)
            Circle().fill(AE.warm.opacity(0.16))
                .frame(width: 88, height: 88).blur(radius: 24)
                .offset(x: 96, y: -28)

            VStack(alignment: .leading, spacing: 16) {
                appIcon
                titleBlock
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 88)

            topBar
        }
        .frame(height: 316)
        .clipShape(BottomRoundedShape(radius: 36))
        .shadow(color: AE.shadowColor, radius: 12, y: 6)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Spacer()
            // 147/148：线路入口（未登录也能用），**只显示城市名，不显示地址**
            Button { showLines = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "location.circle")
                        .font(.system(size: 12))
                    Text("线路 · " + APIClient.activeLine.name)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.88))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.13))
                .clipShape(Capsule())
            }
            Button("帮助") { tip = "如需帮助，请联系 aevis.cn 客服。" }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(
                    colors: [AE.accentLift, AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 72, height: 72)
                .shadow(color: Color.black.opacity(0.28), radius: 14, x: 0, y: 8)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                .frame(width: 72, height: 72)
            Image(systemName: "dog.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("登录发现更多精彩")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("验证码只发给已注册的邮箱；还没有账号就点「去注册」。")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.74))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 表单卡

    private var formCard: some View {
        VStack(spacing: 14) {
            emailField
            if mode == .password || register { passwordField }
            if mode == .code || register { codeRow }
            switchRow
        }
        .padding(16)
        .background(AE.card)
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous))
        .shadow(color: AE.shadowColor, radius: 10, y: 4)
    }

    private var fieldBG: Color {
        Color.adaptive(dark: Color.hex(0x272B35), light: Color.hex(0xF4F2ED))
    }

    private var emailField: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AE.accent.opacity(0.78))
                .frame(width: 20)
            TextField("请输入邮箱", text: $email)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(AE.accent.opacity(0.78))
                .frame(width: 20)
            SecureField("密码：至少 8 位，含字母和数字", text: $password)
                .font(.system(size: 15))
                .focused($focused, equals: .password)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var codeRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "number")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AE.accent.opacity(0.78))
                    .frame(width: 20)
                TextField("邮箱里那 6 位数字", text: $code)
                    .font(.system(size: 15))
                    .keyboardType(.numberPad)
                    .focused($focused, equals: .code)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(fieldBG)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

            Button { Task { await sendCode() } } label: {
                Text(busy ? "发送中" : "发送验证码")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AE.accent)
                    .frame(width: 88, height: 52)
                    .background(AE.accentSoft)
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
                .foregroundStyle(AE.accent)
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
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: canSubmit
                        ? [AE.accentLift, AE.accentDeep]
                        : [Color.hex(0xB6BCC9), Color.hex(0xC7CCD7)],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius + 2, style: .continuous))
            .shadow(color: canSubmit ? AE.accentDeep.opacity(0.26) : .clear, radius: 12, y: 6)
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
        .foregroundStyle(isGood ? AE.accent : Color.hex(0xB4553C))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(AE.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var agreementRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { agree.toggle() }
            } label: {
                ZStack {
                    if agree {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AE.accentDeep).frame(width: 20, height: 20)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.hex(0xC6CAD2), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意用户协议和隐私政策")

            HStack(spacing: 0) {
                Text("已阅读并同意 ").foregroundStyle(AE.textSecondary)
                Link("用户协议", destination: URL(string: "https://aevis.cn/terms.html")!)
                    .foregroundStyle(AE.accent)
                Text(" 和 ").foregroundStyle(AE.textSecondary)
                Link("隐私政策", destination: URL(string: "https://aevis.cn/privacy.html")!)
                    .foregroundStyle(AE.accent)
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
        Color.adaptive(dark: Color.white.opacity(0.12), light: Color.hex(0xE2DFD8))
    }

    // MARK: - 第三方登录

    private var thirdPartyRow: some View {
        HStack(alignment: .center, spacing: 20) {
            // 149：微信 → 唤起小程序（jump_url），失败则出二维码；QQ → 内嵌 WKWebView 授权
            circleButton(icon: "message.fill", label: "微信", tint: Color.hex(0x07C160)) {
                Task { await startWeChat() }
            }
            circleButton(icon: "bubble.left.fill", label: "QQ", tint: Color.hex(0x12B7F5)) {
                qqSheet = true
            }
            circleButton(icon: "qrcode", label: "扫码", tint: AE.accent) {
                showQR = true
            }
            Spacer(minLength: 0)
            Button { showRecover = true } label: {
                Text("找回账号")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .underline(true, color: AE.accent.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
    }

    private func circleButton(
        icon: String, label: String, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    Circle().fill(AE.card).frame(width: 54, height: 54)
                    Circle().stroke(separator, lineWidth: 1).frame(width: 54, height: 54)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
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

    /// 149：唤起小程序 + 轮询；唤起失败就退回二维码
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
                .foregroundStyle(AE.textPrimary)
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
                    .background(AE.accentDeep)
                    .clipShape(RoundedRectangle(cornerRadius: AE.buttonRadius, style: .continuous))
            }
            .disabled(busy || !email.contains("@"))
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

// MARK: - 扫码登录（149：服务端给 image_url，微信唤不起时用它兜底）

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
                .foregroundStyle(AE.textPrimary)
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
                    .background(AE.accentDeep)
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

    private var fieldBGForQR: Color {
        Color.adaptive(dark: Color.hex(0x272B35), light: Color.hex(0xF4F2ED))
    }

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

// MARK: - QQ 网页授权（149：WKWebView 内嵌，不需要 AppID / 自定义 scheme）

struct QQSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onToken: (String) -> Void

    @State private var auth: APIClient.QQAuth?
    @State private var tip = "正在获取授权地址…"

    var body: some View {
        NavigationStack {
            Group {
                if let a = auth {
                    QQWebView(urlString: a.url, callbackPrefix: APIClient.qqCallbackPrefix) { code in
                        Task { await exchange(code: code, state: a.state) }
                    }
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) {
                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 12)).foregroundStyle(AE.textSecondary)
                        .padding(10)
                }
            }
            .navigationTitle("QQ 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        tip = "已取消"
                        dismiss()
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        do {
            auth = try await APIClient.qqAuthURL()
            NSLog("QQ WKWebView start")
        } catch {
            tip = "QQ 授权失败：\(error.localizedDescription)"
        }
    }

    private func exchange(code: String, state: String) async {
        tip = "已拿到 code，正在换登录态…"
        do {
            let token = try await APIClient.qqLogin(code: code, state: state)
            onToken(token)
        } catch {
            tip = "QQ 登录失败：\(error.localizedDescription)"
        }
    }
}

/// WKWebView 包装：拦 redirect_uri 前缀，从 query 取 code 后回调
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


// MARK: - 线路选择（147/148）——只显示城市名，不显示任何地址

struct LineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var active: String = APIClient.activeLine.id

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(APIClient.lines) { line in
                        Button {
                            guard !line.base.isEmpty else { return }
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
                                    Image(systemName: "checkmark").foregroundStyle(AE.accent)
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
            }
            .navigationTitle("线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
