import SwiftUI
import UIKit

/// 登录页（2026-11-17，144 按截图逐项做；接口按 143 的 `/v1/auth/login/email`）。
///
/// 结构从上到下（间距按 8 的倍数）：
///   帮助 → 图标 64 → 标题 28 → 副标 → 邮箱 56 → 「⇄ 密码登录 / 没有账号，去注册」
///   → 胶囊按钮 52 → 协议行 → 小字 → 三个圆（微信 / QQ / 扫码）+ 找回账号
///
/// 规矩：
///   · 未勾协议点按钮 → 提示「请先阅读并同意用户协议和隐私政策。」（真的拦住提交）；
///   · 微信 / QQ 需要 AppID，点了只给明确提示，**绝不假装登录成功**；
///   · 扫码走 `/v1/auth/wx/qr/create` + `/poll`，二维码用 CoreImage 现画（不引第三方库）。
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
                    topBar
                    appIcon.padding(.top, 24)
                    titleBlock.padding(.top, 24)
                    emailField.padding(.top, 20)
                    switchRow.padding(.top, 14)
                    if mode == .password || register { passwordField.padding(.top, 14) }
                    if mode == .code || register { codeRow.padding(.top, 14) }
                    if !tip.isEmpty {
                        Text(tip)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .padding(.top, 10)
                    }
                    submitButton.padding(.top, 22)
                    agreementRow.padding(.top, 16)
                    Text("未注册的邮箱验证通过后将自动创建账号。")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.hex(0x9A9A9A))
                        .padding(.top, 6)
                        .padding(.leading, 28)
                    thirdPartyRow.padding(.top, 40)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = nil }
        }
        .sheet(isPresented: $showRecover) { RecoverView() }
        .sheet(isPresented: $showQR) {
            WxQRView { token in
                showQR = false
                session.save(token: token, email: email)
            }
        }
    }

    // MARK: - 组件

    private var topBar: some View {
        HStack {
            Spacer()
            Button("帮助") { tip = "如需帮助，请联系 aevis.cn 客服。" }
                .font(.system(size: 14))
                .foregroundStyle(Color.hex(0x8A8A8A))
        }
        .padding(.top, 8)
    }

    private var appIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AE.accent.opacity(0.88), AE.accent.opacity(0.55)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
            Image(systemName: "dog.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录发现更多精彩")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.hex(0x1B1D22))
            Text("验证码只发给已注册的邮箱；还没有账号就点「去注册」。")
                .font(.system(size: 13))
                .foregroundStyle(Color.hex(0x8A8A8A))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldBG: Color { Color.adaptive(dark: Color.hex(0x2A2A2E), light: Color.hex(0xECE9E2)) }

    private var emailField: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.system(size: 18))
                .foregroundStyle(Color.hex(0x9A9A9A))
            TextField("请输入邮箱", text: $email)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 18))
                .foregroundStyle(Color.hex(0x9A9A9A))
            SecureField("密码：至少 8 位，含字母和数字", text: $password)
                .font(.system(size: 15))
                .focused($focused, equals: .password)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(fieldBG)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var codeRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "number")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.hex(0x9A9A9A))
                TextField("邮箱里那 6 位数字", text: $code)
                    .font(.system(size: 15))
                    .keyboardType(.numberPad)
                    .focused($focused, equals: .code)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(fieldBG)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                Task { await sendCode() }
            } label: {
                Text(busy ? "发送中" : "发送验证码")
                    .font(.system(size: 13))
                    .foregroundStyle(AE.accent)
                    .frame(width: 92, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AE.accent.opacity(0.45), lineWidth: 1)
                    )
            }
            .disabled(busy || !email.contains("@"))
        }
    }

    private var switchRow: some View {
        HStack {
            Button {
                mode = (mode == .code) ? .password : .code
                tip = ""
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12))
                    Text(mode == .code ? "密码登录" : "验证码登录")
                        .font(.system(size: 14))
                }
                .foregroundStyle(AE.accent)
            }
            Spacer()
            Button(register ? "已经有账号，去登录" : "没有账号，去注册") {
                register.toggle()
                tip = ""
            }
            .font(.system(size: 14))
            .foregroundStyle(Color.hex(0x8A8A8A))
        }
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            Text(buttonTitle)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(canSubmit ? AE.accent : Color.hex(0xC9BFF5))
                .clipShape(Capsule())
        }
        .disabled(busy)
    }

    private var agreementRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { agree.toggle() } label: {
                Image(systemName: agree ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(agree ? AE.accent : Color.hex(0xC9C4BC))
            }
            HStack(spacing: 0) {
                Text("已阅读并同意 ").foregroundStyle(Color.hex(0x8A8A8A))
                Link("用户协议", destination: URL(string: "https://aevis.cn/terms.html")!)
                    .foregroundStyle(AE.accent)
                Text(" 和 ").foregroundStyle(Color.hex(0x8A8A8A))
                Link("隐私政策", destination: URL(string: "https://aevis.cn/privacy.html")!)
                    .foregroundStyle(AE.accent)
            }
            .font(.system(size: 13))
        }
    }

    private var thirdPartyRow: some View {
        HStack(alignment: .top, spacing: 24) {
            circleButton(bg: Color.hex(0x07C160), icon: "message.fill", label: "微信") {
                tip = "需要配置 AppID，暂不可用"
            }
            circleButton(bg: Color.hex(0x12B7F5), icon: "bubble.left.fill", label: "QQ") {
                tip = "需要配置 AppID，暂不可用"
            }
            circleButton(
                bg: Color.adaptive(dark: AE.accent.opacity(0.18), light: Color.hex(0xEDE9FB)),
                icon: "qrcode", label: "扫码", tintOverride: AE.accent
            ) {
                showQR = true
            }
            Spacer()
            Button {
                showRecover = true
            } label: {
                Text("找回账号")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.hex(0x6B6B6B))
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .overlay(Capsule().stroke(Color.hex(0xDDD9D2), lineWidth: 1))
            }
            .padding(.top, 10)
        }
    }

    private func circleButton(
        bg: Color, icon: String, label: String,
        tintOverride: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Button(action: action) {
                ZStack {
                    Circle().fill(bg).frame(width: 56, height: 56)
                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(tintOverride ?? .white)
                }
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.hex(0x8A8A8A))
        }
    }

    // MARK: - 行为

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
            session.save(token: r.token, email: email)
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

// MARK: - 找回账号

struct RecoverView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var tip = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("找回账号").font(.system(size: 22, weight: .bold))
            Text("输入注册邮箱，我们会发送一条验证码；验证通过后可重设密码。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("注册邮箱", text: $email)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            if !tip.isEmpty {
                Text(tip).font(.system(size: 12)).foregroundStyle(.secondary)
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
                    .frame(maxWidth: .infinity).frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy || !email.contains("@"))
            Spacer()
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

// MARK: - 扫码登录（146：微信/通用扫码，CoreImage 现画二维码）

struct WxQRView: View {
    @Environment(\.dismiss) private var dismiss
    /// 拿到 token 后回调（交给 Session 保存）
    var onToken: (String) -> Void

    @State private var qrImage: UIImage?
    @State private var content = ""
    @State private var tip = "正在获取二维码…"
    @State private var polling = false
    @State private var cancelled = false

    var body: some View {
        VStack(spacing: 18) {
            Text("用微信扫码登录").font(.system(size: 20, weight: .semibold))
            Text("也可以点下方按钮打开微信，再扫这张码")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.hex(0xF2F0EA))
                    .frame(width: 240, height: 240)
                if let img = qrImage {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 208, height: 208)
                } else {
                    ProgressView()
                }
            }

            Text(tip).font(.system(size: 12)).foregroundStyle(.secondary)

            Button {
                if let u = URL(string: "weixin://"), UIApplication.shared.canOpenURL(u) {
                    UIApplication.shared.open(u)
                } else {
                    tip = "未安装微信"
                }
            } label: {
                Text("打开微信").frame(maxWidth: .infinity).frame(height: 46)
            }
            .buttonStyle(.borderedProminent)

            Button("取消") {
                cancelled = true
                dismiss()
            }
            .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(24)
        .presentationDetents([.large])
        .interactiveDismissDisabled(false)
        .task { await start() }
    }

    private func start() async {
        do {
            let r = try await APIClient.wxQRCreate()
            content = r.content
            qrImage = Self.qrImage(from: r.content)
            tip = "等待微信扫码…（最长 120 秒）"
            await poll(id: r.id)
        } catch {
            tip = "获取二维码失败：\(error.localizedDescription)"
        }
    }

    private func poll(id: String) async {
        polling = true
        defer { polling = false }
        let deadline = Date().addingTimeInterval(120)
        while !cancelled && Date() < deadline {
            do {
                if let token = try await APIClient.wxQRPoll(id: id) {
                    tip = "登录成功"
                    onToken(token)
                    return
                }
            } catch {
                tip = "轮询失败：\(error.localizedDescription)"
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if !cancelled { tip = "二维码已过期，请重试" }
    }

    /// CoreImage 画二维码，不引第三方库
    static func qrImage(from text: String) -> UIImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(text.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter?.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
