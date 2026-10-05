import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// App 的**登录门** —— 用户 2026-09-28 拍板要的东西。
///
/// ## 用户的原话（一句都没改）
/// 「你先进去，就是先那个设备码，然后你还要登录账号，登录账号，你不要跳转网页了吧……
///   邮箱验证码那些也是内置啊」
/// 「除了 QQ 的话，QQ 那边点一下，你跳转内置网页，然后再跳转那个……
///   我希望还是内置的 APP，但是通过那个链接直接跳转，就不走浏览器，
///   但是浏览器直接跳转到 QQ 那里」
/// 「你一定要强制性登录的，去退出登录的话，就回到初始界面，就要登录账号」
///
/// ## 所以这里有三条路，**全在 App 里做完**
/// 1. **验证码登录**：邮箱 → 收码 → 登（服务端 `/api/send_code` + `/api/verify`）
/// 2. **密码登录**：账号号 / 邮箱 + 密码（`/api/login`，两样都能填）
/// 3. **用 QQ 登录**：走**内置**浏览器（`ASWebAuthenticationSession`）跳 QQ 授权页，
///    授权完由服务端 302 回 `aevis://login?token=…` → 浏览器自己收工、把 token 交回来。
///    这是唯一一处用浏览器的地方 —— 因为 QQ 那边必须在浏览器环境里跳。
///
/// 另外还有「我有注册码」：注册也搬进 App 了，不用再去网页。
/// 这样新买家拿到注册码之后**根本不需要打开浏览器**。
struct LoginView: View {

    @ObservedObject private var account = AccountService.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var tab: Tab = .code

    // —— 验证码登录 ——
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false

    // —— 密码登录 ——
    @State private var accountField = ""
    @State private var password = ""

    // —— 注册码注册 ——
    @State private var invite = ""
    @State private var invited = false

    @State private var working = false
    @State private var note: String?
    @State private var noteIsBad = false

    // —— 手机扫码登录（2026-10-03）——
    /// 扫码那一页是不是正开着。
    @State private var showScan = false
    /// iPad 上**自动弹一次**扫码页，别弹第二次（用户关掉就是不想用）。
    @State private var didAutoOfferScan = false

    /// 这台设备是不是 iPad。
    ///
    /// 老板原话：「如果检测到登录的设备是 iPad，支持手机扫码登录」——
    /// 检测到 iPad 就把它当**首选**（自动弹出来）；iPhone 上仍然找得到，
    /// 只是不抢主动（iPhone 上敲验证码本来就不难，弹出来反而是打扰）。
    private var isPad: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    enum Tab: String, CaseIterable, Identifiable {
        case code, password, register

        var id: String { rawValue }

        var label: String {
            switch self {
            case .code: return "验证码登录"
            case .password: return "密码登录"
            case .register: return "我有注册码"
            }
        }
    }

    var body: some View {
        ZStack {
            // 登录页也是「开始页」这条路上的一环（门禁 → 登录 → 主界面），
            // 背景跟 RootView 的 `.start` 保持一致 —— 不然从门禁进登录会"啪"一下变脸。
            AevisBackground(scope: .start)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if isPad { scanCallout }
                    switcher
                    card
                    qqButton
                    if !isPad { scanButton }

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(noteIsBad ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 34)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showScan) {
            ScanLoginView {
                // 登录成功。`RootView` 会把整棵树换成主界面（它盯着 isSignedIn），
                // 所以这里只要把这一页收掉就行。
                showScan = false
            }
        }
        // iPad：进来就先把扫码那条路摆到面前。⚠️ 延后 0.4 秒再弹 ——
        // 在视图还没画完的时候弹 sheet，SwiftUI 会"吞掉"这一次（表现是点了没反应）。
        .task {
            guard isPad, !didAutoOfferScan else { return }
            didAutoOfferScan = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            showScan = true
        }
    }

    // MARK: - 头

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            AevisOrb()
                .scaleEffect(0.62)
                .frame(height: 62)

            Text("登录 Aevis")
                .font(.aevis(23, weight: .semibold))
                .foregroundStyle(.primary)

            Text("登录之后 TA 才能记住你 —— 人设、聊天记录、记忆都还只存在这台手机上。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 三条路的切换

    private var switcher: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                Button {
                    note = nil
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                } label: {
                    Text(item.label)
                        .font(.aevis(13, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.primary.opacity(tab == item ? 0.10 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .aevisGlass(cornerRadius: 14)
    }

    // MARK: - 表单

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 13) {
            switch tab {
            case .code: codeForm
            case .password: passwordForm
            case .register: registerForm
            }
        }
        .padding(16)
        .aevisGlass(cornerRadius: 18)
    }

    private var codeForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            field("邮箱", placeholder: "你注册时用的邮箱", text: $email, secret: false)

            if codeSent {
                field("验证码", placeholder: "邮箱里那 6 位数字", text: $code,
                      secret: false, isCode: true)
            }

            HStack(spacing: 10) {
                if codeSent {
                    Button {
                        run { try await account.signIn(email: email, code: code) }
                    } label: {
                        primaryLabel(working ? "登录中…" : "登录")
                    }
                    .disabled(working || code.isEmpty)

                    Button {
                        run { try await account.sendLoginCode(email: email); codeSent = true }
                    } label: {
                        secondaryLabel("重发")
                    }
                    .disabled(working || email.isEmpty)
                } else {
                    Button {
                        run { try await account.sendLoginCode(email: email); codeSent = true }
                    } label: {
                        primaryLabel(working ? "发送中…" : "发验证码")
                    }
                    .disabled(working || email.isEmpty)
                }

                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }

            Text("验证码只发给「已经注册过」的邮箱。没注册过的话，用「我有注册码」那条路。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            field("账号", placeholder: "账号号或邮箱", text: $accountField, secret: false)
            field("密码", placeholder: "密码", text: $password, secret: true)

            HStack(spacing: 10) {
                Button {
                    run { try await account.signIn(account: accountField, password: password) }
                } label: {
                    primaryLabel(working ? "登录中…" : "登录")
                }
                .disabled(working || accountField.isEmpty || password.isEmpty)

                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }

            Text("没设过密码的话，先用「验证码登录」进去，再到「设置 → 账号」里设一个。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var registerForm: some View {
        VStack(alignment: .leading, spacing: 13) {
            field("注册码", placeholder: "群里机器人给你的那串", text: $invite, secret: false)
            field("邮箱", placeholder: "用来收验证码的邮箱", text: $email, secret: false)

            if invited {
                field("验证码", placeholder: "邮箱里那 6 位数字", text: $code,
                      secret: false, isCode: true)
            }

            HStack(spacing: 10) {
                if invited {
                    Button {
                        run {
                            try await account.registerFinish(code: invite, email: email,
                                                              emailCode: code)
                        }
                    } label: {
                        primaryLabel(working ? "注册中…" : "注册并登录")
                    }
                    .disabled(working || code.isEmpty)
                } else {
                    Button {
                        run { try await account.registerStart(code: invite, email: email); invited = true }
                    } label: {
                        primaryLabel(working ? "验证中…" : "下一步")
                    }
                    .disabled(working || invite.isEmpty || email.isEmpty)
                }

                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }

            Text("注册码在 QQ 群 683699963 里找机器人领，一人一码。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - QQ

    /// iPad 上最显眼的那一条：直接进扫码页。
    private var scanCallout: some View {
        Button {
            showScan = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.aevis(17))
                VStack(alignment: .leading, spacing: 2) {
                    Text("用手机扫码登录")
                        .font(.aevis(15, weight: .semibold))
                    Text("不用在这台设备上敲邮箱和验证码")
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.aevis(12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    /// iPhone 上它在最下面，一个安静的入口。
    private var scanButton: some View {
        Button {
            showScan = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.aevis(15))
                Text("用手机扫码登录")
                    .font(.aevis(15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private var qqButton: some View {
        Button {
            loginWithQQ()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.aevis(15))
                Text("用 QQ 登录")
                    .font(.aevis(15, weight: .medium))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .aevisGlass(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .disabled(working)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("一个账号可以在这台设备上一直用，换设备要在群里说一声。")
            Text("账号只是「钥匙」—— TA 的样子、你们聊过的东西，从来不经过服务器。")
        }
        .font(.aevis(11.5))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 4)
    }

    // MARK: - 零件

    private func field(_ label: String, placeholder: String, text: Binding<String>,
                       secret: Bool, isCode: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.aevis(12))
                .foregroundStyle(.secondary)

            Group {
                if secret {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.aevis(15))
            // ⚠️ 邮箱不能自动大写、不能自动纠错 —— 大写的邮箱在服务端是另一个人。
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(isCode ? .numberPad : .default)
            .textContentType(isCode ? .oneTimeCode : (secret ? .password : .emailAddress))
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.aevis(15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .aevisGlass(cornerRadius: 14)
    }

    private func secondaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.aevis(14))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
    }

    // MARK: - 动作

    /// 所有按钮都走它：统一打理"忙不忙"和"把错误说清楚"。
    private func run(_ work: @escaping () async throws -> Void) {
        guard !working else { return }
        note = nil
        noteIsBad = false
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await work()
            } catch {
                note = error.localizedDescription
                noteIsBad = true
            }
        }
    }

    /// QQ：内置浏览器跳授权 → 服务端把 token 送回 `aevis://login`。
    private func loginWithQQ() {
        guard let url = account.qqLoginURL() else {
            note = "账号服务器地址不对，检查一下「设置 → 账号」里的地址。"
            noteIsBad = true
            return
        }
        guard !working else { return }
        note = nil
        noteIsBad = false
        working = true

        Task { @MainActor in
            defer { working = false }
            // ⚠️ scheme 必须是 `aevis` —— 服务端就是往这个 scheme 跳的
            //    （`AEVIS_APP_SCHEME`，默认 aevis）。对不上就永远收不到回调，
            //    表现是"点了 QQ 登录，转一圈没反应"。
            let callback = await WebAuth.shared.run(url: url, scheme: appScheme)
            guard let callback else {
                return          // 用户自己取消的，不用弹红字
            }
            let params = callback.queryParameters
            if let token = params["token"], !token.isEmpty {
                do {
                    try await account.adoptWebToken(token)
                } catch {
                    note = error.localizedDescription
                    noteIsBad = true
                }
                return
            }
            note = qqFailureText(params["qq_error"])
            noteIsBad = true
        }
    }

    private var appScheme: String {
        (Bundle.main.object(forInfoDictionaryKey: "AEVIS_APP_SCHEME") as? String) ?? "aevis"
    }

    private func qqFailureText(_ code: String?) -> String {
        switch code {
        case nil:
            return "QQ 授权没走完，再点一次试试。"
        case "not_configured":
            return "服务器上还没配好 QQ 登录，先用验证码登录吧。"
        case "state_expired":
            return "这次授权过期了，再点一次。"
        case "blocked":
            return "这个账号已被停用，有疑问联系管理员。"
        case let other?:
            return "QQ 登录失败（\(other)），换个方式登录吧。"
        }
    }
}

private extension URL {
    /// 把 `?a=1&b=2` 拆成字典（QQ 回调那一跳要用）。
    var queryParameters: [String: String] {
        guard let items = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}
