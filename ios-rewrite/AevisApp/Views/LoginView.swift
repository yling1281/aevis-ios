import SwiftUI
import UIKit
import WebKit

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
        .sheet(isPresented: $showLines) { LineSheet() }
        .sheet(isPresented: $qqSheet) {
            QQSheet { token in
                qqSheet = false
                session.save(token: token, email: email)
            }
        }
        .sheet(item: Binding(
            get: { wxQR.map { WXItem(info: $0) } },
            set: { if $0 == nil { wxQR = nil } }
        )) { item in
            WxQRView(info: item.info) { token in
                wxQR = nil
                session.save(token: token, email: email)
            }
        }
        .sheet(isPresented: $showQR) {
            WxQRView { token in
                showQR = false
                session.save(token: token, email: email)
            }
        }
    }

    // MARK: - 组件

    private var topBar: some View {
        HStack(spacing: 16) {
            Spacer()
            // 147/148：线路入口（未登录也能用），**只显示城市名，不显示地址**
            Button {
                showLines = true
            } label: {
                HStack(spacing: 3) {
                    Text("线路 · " + APIClient.activeLine.name)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.hex(0x8A8A8A))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.hex(0xB0B0B0))
                }
            }
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
            // 149：微信 → 唤起小程序（jump_url），失败则出二维码；QQ → 内嵌 WKWebView 授权
            circleButton(bg: Color.hex(0x07C160), icon: "message.fill", label: "微信") {
                Task { await startWeChat() }
            }
            circleButton(bg: Color.hex(0x12B7F5), icon: "bubble.left.fill", label: "QQ") {
                qqSheet = true
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
                if let token = try? await APIClient.wxQRPoll(ticket: info.ticket), let t = token {
                    session.save(token: t, email: email)
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
            Text("用微信扫码登录").font(.system(size: 20, weight: .semibold))
            Text("也可以点下方按钮打开微信，再扫这张码")
                .font(.system(size: 12)).foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.hex(0xF2F0EA)).frame(width: 240, height: 240)
                if let u = imageURL {
                    AsyncImage(url: u) { img in
                        img.resizable().interpolation(.none).scaledToFit()
                    } placeholder: { ProgressView() }
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
        .task { await poll() }
    }

    private func poll() async {
        let deadline = Date().addingTimeInterval(180)
        while !cancelled && Date() < deadline {
            if let token = try? await APIClient.wxQRPoll(ticket: info.ticket), let t = token {
                tip = "登录成功"
                onToken(t)
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
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
