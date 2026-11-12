import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
#if canImport(SafariServices)
import SafariServices
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
/// ## 版式（2026-11-12 重做，照抖音那版）
/// 用户给了抖音的登录页截图，原话「你的登录界面不要这么做啊我靠……你看一下抖音的登录」。
/// 所以整页按那个语汇走：
///
/// ```
///                                   帮助
/// 登录发现更多精彩
/// 未注册的邮箱验证通过后将自动注册
/// ┌──────────────────────────────┐
/// │ ✉  请输入邮箱                 │
/// └──────────────────────────────┘
/// ⇄ 密码登录      没有账号，去注册
/// [        验证并登录        ]      ← 整宽胶囊，禁用态是淡色
/// ○ 已阅读并同意 用户协议 和 隐私政策
///
///      ⭕微信    ⭕QQ    ⭕扫码    [找回账号]
/// ```
///
/// **微信 / QQ 从上半屏收到最下面那排圆圈**，主路径只剩「输入 → 验证 → 登录」。
///
/// ## 几条不能破的
/// 1. **强制登录**：这一页不提供"跳过"。
/// 2. **协议必须自己勾**：没勾点登录只提示，不替用户同意。
/// 3. QQ 走**系统浏览器**（不是 `ASWebAuthenticationSession`）——
///    后者是应用内 Safari，QQ 授权页在里面收不到 `aevis://login` 回调。
/// 4. 微信直接拉起小程序（`weixin://dl/business/...`），跳不动才退回扫码。
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

    // —— 注册（邮箱 + 密码 + 验证码；2026-10-31 起不再需要注册码）——
    @State private var invited = false

    @State private var working = false
    @State private var note: String?
    @State private var noteIsBad = false

    // —— 抖音式登录页（2026-11-12）——
    /// 协议勾选。没勾就点登录会标红提示，**不会**悄悄替用户同意。
    @State private var agreed = false
    @State private var showHelp = false
    @State private var showTerms = false
    @State private var showPrivacy = false

    // —— 手机扫码登录（2026-10-03）——
    /// 扫码那一页是不是正开着。
    @State private var showScan = false
    /// iPad 上**自动弹一次**扫码页，别弹第二次（用户关掉就是不想用）。
    @State private var didAutoOfferScan = false

    /// 微信登录（扫码走我们自己的小程序）。2026-11-02 加。
    @State private var showWXLogin = false

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
            case .register: return "注册"
            }
        }
    }

    var body: some View {
        ZStack {
            // 登录页也是「开始页」这条路上的一环（门禁 → 登录 → 主界面），
            // 背景跟 RootView 的 `.start` 保持一致 —— 不然从门禁进登录会"啪"一下变脸。
            AevisBackground(scope: .start)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 🔴 2026-11-12 用户给了抖音的登录页做参照，原话：
                    //    「你的登录界面不要这么做啊我靠……你看一下抖音的登录」。
                    //    所以整页按那个语汇重排：**顶部返回+帮助 → 大标题 → 单个大输入框
                    //    → 切换行 → 整宽主按钮 → 协议 → 底部小圆圈**。
                    //    微信/QQ 不再占上半屏，全部收到最下面那排圆圈里。
                    navBar
                        .padding(.bottom, 26)

                    titleBlock
                        .padding(.bottom, 26)

                    inputBlock
                        .padding(.bottom, 14)

                    switchLine
                        .padding(.bottom, 22)

                    actionButton

                    agreeLine
                        .padding(.top, 14)

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(noteIsBad ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 12)
                    }

                    // 把底部那排推下去：抖音的圆圈是贴着键盘上沿的，
                    // 内容不满一屏时用固定间距顶住，不要挤在按钮下面。
                    Spacer(minLength: 96)

                    bottomActions
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showWXLogin) {
            WXLoginSheet {
                showWXLogin = false
            }
        }
        .sheet(isPresented: $showScan) {
            ScanLoginView {
                // 登录成功。`RootView` 会把整棵树换成主界面（它盯着 isSignedIn），
                // 所以这里只要把这一页收掉就行。
                showScan = false
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack { RulesView() }
        }
        // 协议用**应用内 Safari**（不是跳出 App）：登录页读协议不该把人送出应用。
        .sheet(isPresented: $showTerms) {
            LoginWebSheet(url: AevisHosts.siteURL("/terms.html"))
        }
        .sheet(isPresented: $showPrivacy) {
            LoginWebSheet(url: AevisHosts.siteURL("/privacy.html"))
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

    // MARK: - 顶部：帮助
    //
    // ⚠️ 抖音那版左上角有个返回箭头 —— 那是它从「我」页进来的。我们这里是**强制登录门禁**
    //    （`RootView.gated` 按 `needsLogin` 整棵换树），没有"上一页"可退，
    //    画一个点了没反应的箭头比不画更糟。所以只保留右上「帮助」。

    private var navBar: some View {
        HStack {
            Spacer()

            Button {
                showHelp = true
            } label: {
                Text("帮助")
                    .font(.aevis(15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: - 标题

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录发现更多精彩")
                .font(.aevis(25, weight: .semibold))
                .foregroundStyle(.primary)

            // ⚠️ 这里**不能**照抄抖音那句「未注册的手机号验证通过后将自动注册」——
            //    我们的注册要设密码（`/v1/auth/register` 收 email + password + code），
            //    验证码登录只对**已注册**邮箱发码。照抄就是骗人，用户会卡在"发了码收不到"。
            Text(isRegistering
                 ? "邮箱 + 密码 + 验证码，注册即赠 30 天体验"
                 : "验证码只发给已注册的邮箱；还没有账号就点「去注册」")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 输入区

    /// 抖音那种：一个大圆角浅灰底，里面是图标 + 输入，**没有外框标签**。
    @ViewBuilder
    private var inputBlock: some View {
        VStack(spacing: 12) {
            switch tab {
            case .code:
                bigField(icon: "envelope",
                         placeholder: "请输入邮箱",
                         text: $email,
                         keyboard: .emailAddress)
                if codeSent {
                    bigField(icon: "number",
                             placeholder: "邮箱里那 6 位数字",
                             text: $code,
                             keyboard: .numberPad,
                             oneTimeCode: true)
                }

            case .password:
                bigField(icon: "person",
                         placeholder: "邮箱或手机号",
                         text: $accountField,
                         keyboard: .emailAddress)
                bigField(icon: "lock",
                         placeholder: "密码",
                         text: $password,
                         keyboard: .default,
                         secret: true)

            case .register:
                bigField(icon: "envelope",
                         placeholder: "用来收验证码的邮箱",
                         text: $email,
                         keyboard: .emailAddress)
                bigField(icon: "lock",
                         placeholder: "密码：至少 8 位，含字母和数字",
                         text: $password,
                         keyboard: .default,
                         secret: true)
                if invited {
                    bigField(icon: "number",
                             placeholder: "邮箱里那 6 位数字",
                             text: $code,
                             keyboard: .numberPad,
                             oneTimeCode: true)
                }
            }
        }
    }

    /// 大圆角输入框（抖音同款）。`secret` 用 SecureField，`oneTimeCode` 打开一次性验证码键盘。
    @ViewBuilder
    private func bigField(icon: String, placeholder: String, text: Binding<String>,
                          keyboard: UIKeyboardType,
                          secret: Bool = false,
                          oneTimeCode: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.aevis(15))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Group {
                if secret {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.aevis(15.5))
            // ⚠️ 邮箱不能自动大写、不能自动纠错 —— 大写的邮箱在服务端是另一个人。
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .textContentType(oneTimeCode ? .oneTimeCode : (secret ? .password : .emailAddress))

            if working {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    // MARK: - 切换行（验证码 ⇄ 密码 ⇄ 注册）

    private var switchLine: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    tab = (tab == .code) ? .password : .code
                    codeSent = false
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.aevis(12, weight: .medium))
                    Text(tab == .code ? "密码登录" : "验证码登录")
                        .font(.aevis(13.5))
                }
                .foregroundStyle(settings.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(working)

            if tab != .register {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        tab = .register
                        invited = false
                    }
                } label: {
                    Text("没有账号，去注册")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(working)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = .code }
                } label: {
                    Text("已经有账号，去登录")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(working)
            }

            Spacer(minLength: 0)
        }
    }

    private var isRegistering: Bool { tab == .register }

    // MARK: - 主按钮

    /// 整宽胶囊按钮。**禁用态是淡色**（跟抖音一样），不是灰块 —— 一眼看出"还差一步"。
    private var actionButton: some View {
        Button {
            primaryAction()
        } label: {
            Text(actionTitle)
                .font(.aevis(16.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Capsule().fill(actionEnabled
                                   ? settings.accentColor
                                   : settings.accentColor.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!actionEnabled || working)
    }

    private var actionTitle: String {
        if working { return "处理中…" }
        switch tab {
        case .code:     return codeSent ? "登录" : "验证并登录"
        case .password: return "登录"
        case .register: return invited ? "注册并登录" : "发送验证码"
        }
    }

    private var actionEnabled: Bool {
        switch tab {
        case .code:
            if codeSent { return !code.isEmpty }
            return !email.trimmingCharacters(in: .whitespaces).isEmpty
        case .password:
            return !accountField.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .register:
            if invited { return !code.isEmpty && password.count >= 8 }
            return !email.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 8
        }
    }

    private func primaryAction() {
        switch tab {
        case .code:
            if codeSent {
                guard agreed else { rememberAgreement(); return }
                run { try await account.signIn(email: email, code: code) }
            } else {
                guard agreed else { rememberAgreement(); return }
                run {
                    try await account.sendLoginCode(email: email)
                    codeSent = true
                }
            }
        case .password:
            guard agreed else { rememberAgreement(); return }
            run { try await account.signIn(account: accountField, password: password) }
        case .register:
            if invited {
                guard agreed else { rememberAgreement(); return }
                run {
                    try await account.register(email: email, password: password, code: code)
                }
            } else {
                guard agreed else { rememberAgreement(); return }
                run {
                    try await account.requestRegisterCode(email: email)
                    invited = true
                }
            }
        }
    }

    /// 没勾协议就点登录：**把勾选框标红并滚到可见**，不要只弹一句看不清的提示。
    private func rememberAgreement() {
        note = "请先阅读并同意用户协议和隐私政策。"
        noteIsBad = true
    }

    // MARK: - 协议

    private var agreeLine: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                agreed.toggle()
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.aevis(15))
                    .foregroundStyle(agreed ? settings.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text("已阅读并同意 ")
                        .foregroundStyle(.secondary)
                    Button("用户协议") { showTerms = true }
                        .foregroundStyle(settings.accentColor)
                    Text(" 和 ")
                        .foregroundStyle(.secondary)
                    Button("隐私政策") { showPrivacy = true }
                        .foregroundStyle(settings.accentColor)
                }
                .font(.aevis(11.5))

                Text("未注册的邮箱验证通过后将自动创建账号。")
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - 底部：微信 / QQ / 找回账号（小圆圈）

    private var bottomActions: some View {
        HStack(spacing: 14) {
            circleEntry("微信", symbol: "message.fill",
                        color: Color(red: 0.29, green: 0.72, blue: 0.36),
                        enabled: !working) {
                showWXLogin = true
            }

            circleEntry("QQ", symbol: "bubble.left.and.bubble.right.fill",
                        color: Color(red: 0.26, green: 0.55, blue: 0.93),
                        enabled: !working) {
                loginWithQQ()
            }

            circleEntry("扫码", symbol: "qrcode.viewfinder",
                        color: Color(red: 0.42, green: 0.44, blue: 0.55),
                        enabled: !working) {
                showScan = true
            }

            Button {
                showHelp = true
            } label: {
                Text("找回账号")
                    .font(.aevis(13.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 0.8))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    /// 一个圆形入口：52pt 圆底 + 图标，下面 11pt 字。
    private func circleEntry(_ title: String, symbol: String, color: Color,
                             enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.13))
                        .frame(width: 52, height: 52)
                    Image(systemName: symbol)
                        .font(.aevis(20, weight: .medium))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.aevis(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - 头

    // MARK: - 零件

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

    /// QQ：**系统浏览器**跳授权 → 服务端 302 回 `aevis://login` → `RootView.onOpenURL` 收。
    ///
    /// 🔴 2026-11-12 用户明确：「QQ 的那个登录不是内置浏览器，是切换到系统的那个浏览器，
    ///    不要用里面的那个内置浏览器」。原来走 `WebAuth`（`ASWebAuthenticationSession`），
    ///    那是**应用内**的 Safari 视图：QQ 授权页里再要拉起 QQ 客户端、或在它自己的
    ///    域间跳转时，这个内嵌视图经常收不到 `aevis://` 回调 —— 用户看到的就是
    ///    「QQ 回调有问题」。改用 `UIApplication.shared.open` 交给**真 Safari**，
    ///    回调走系统的 URL scheme 唤起（`RootView.onOpenURL` → `receiveWebLogin`），
    ///    这条路本来就已经实现好了，只是没被 QQ 用上。
    private func loginWithQQ() {
        guard !working else { return }
        note = nil
        noteIsBad = false
        working = true

        Task { @MainActor in
            // 🔴 2026-10-31：4-4 改成先进程问一次授权地址（`POST /v1/auth/qq/url`），
            //    所以这里必须先 await 拿到 URL 才能开浏览器。
            //    拿不到只有两种原因：服务端没配 QQ 互联，或网络断了 ——
            //    两种都给同一句人话，别让用户去猜"账号服务器地址不对"。
            guard let url = await account.qqLoginURL() else {
                working = false
                note = "QQ 登录暂不可用（服务端还未配置 QQ 互联），先用邮箱验证码登录吧。"
                noteIsBad = true
                return
            }
            #if canImport(UIKit)
            UIApplication.shared.open(url) { opened in
                if !opened {
                    Task { @MainActor in
                        working = false
                        note = "打不开浏览器。请检查系统里是否限制了打开网页。"
                        noteIsBad = true
                    }
                } else {
                    // 交出去了就不再拦着按钮 —— 用户可能在 Safari 里待一会儿。
                    // 真正的结果由 `RootView.onOpenURL` 带回来。
                    Task { @MainActor in working = false }
                }
            }
            #else
            working = false
            #endif
        }
    }

}

/// 登录页里读协议用的**应用内 Safari**。
///
/// 为什么不用 `UIApplication.shared.open`：那会把用户整个送出 App，
/// 读完协议还得切回来 —— 登录这件小事不该产生两次上下文切换。
struct LoginWebSheet: View {
    let url: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    #if canImport(SafariServices) && canImport(UIKit)
                    SafariBox(url: url)
                        .ignoresSafeArea(edges: .bottom)
                    #else
                    Text("这台设备打不开网页。")
                        .font(.aevis(14))
                        .foregroundStyle(.secondary)
                    #endif
                } else {
                    Text("条款地址没配置。")
                        .font(.aevis(14))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("条款")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

#if canImport(SafariServices) && canImport(UIKit)
private struct SafariBox: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
