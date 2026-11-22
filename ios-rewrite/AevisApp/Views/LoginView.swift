import SwiftUI
import UIKit
import WebKit
import AuthenticationServices

// MARK: - 登录相关界面的视觉令牌（本文件专用）
//
// 收敛规则（改样式只改这里，别在 View 里撒魔法数）：
//   · 一个强调色 LK.accent（墨靛深 #2F3A56）+ 一种页面底 AE.paper + 白卡 + 1px 细描边；
//   · 不用渐变、不用发光、不用多层阴影；层次靠留白、描边、字重；
//   · 圆角只用 16（卡片）/ 12（输入框、按钮）/ 10（小按钮）；不用 Capsule 药丸；
//   · 字号只用 22 / 16 / 13 / 12 四档；不用 .rounded 设计，不用 27+ 的夸大头图字。
private enum LK {
    /// 唯一强调色：主按钮实底、选中标记
    static let accent = AE.accentDeep
    /// 输入框内底（比卡片深一档，保证输入区有边界感）
    static let well = AE.brandWell
    /// 1px 细描边：浅色暖灰 / 深色低透明白
    static let hairline = Color.adaptive(dark: Color.white.opacity(0.14), light: Color.hex(0xE3DED4))
    /// 聚焦描边（比 hairline 深，浅色变深、深色变亮）
    static let focusLine = AE.brandInk.opacity(0.55)
    /// 状态色：只用于小圆点/一行文字，不铺整块背景
    static let ok = Color.adaptive(dark: Color.hex(0x6FCF97), light: Color.hex(0x1E7A4E))
    /// 延迟第二档（80–200ms 的黄绿）：介于绿和橙之间，绿色够深以免在浅底上发飘
    static let lime = Color.adaptive(dark: Color.hex(0xB7D06A), light: Color.hex(0x6B8F1B))
    static let warn = Color.adaptive(dark: Color.hex(0xF0B36B), light: Color.hex(0xB26A00))
    static let bad = Color.adaptive(dark: Color.hex(0xF08A84), light: Color.hex(0xC0392B))
}

/// 登录页（2026-11-22 改版 · 去 AI 味）。
///
/// 用户原话：「界面有些怪怪的，一股 AI 味」。旧版的问题被逐条拆掉：
///   ✗ 顶部两团柔紫/暖橙发光圆（`Circle().blur(40)`）
///   ✗ 柔紫 #9B8AF0 当主色（按钮/链接/图标到处都是）
///   ✗ logo 带紫色光晕投影、卡片带紫雾投影、按钮带发光阴影
///   ✗ 27pt rounded bold 大标语 + 76pt 贴纸感 logo
///   ✗ 52pt 彩色圆形「贴纸」第三方入口
///   ✗ 药丸胶囊主按钮（Capsule + 50pt 高）
///   ✗ 半透明柔紫胶囊提示条
///
/// 现在：中性浅灰底 `AE.paper` + 一张白卡（1px 暖灰描边、16 圆角）。
/// 唯一强调色是墨靛深 `AE.accentDeep`；层次靠留白和描边，不靠渐变与发光。
/// 字号只有四档：22 semibold（页标题）/ 16（输入框、主按钮）/ 13（说明、链接）/ 12（脚注）。
/// 登录内容仍然一屏放下（矮屏收紧），不引入 ScrollView。
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
    /// 验证码重发冷却剩余秒数（>0 时禁点，倒计时到 0 恢复可发）
    @State private var resendLeft = 0
    /// 冷却的绝对到期时刻：App 切后台被挂起后回到前台，用它重算剩余秒数，
    /// 避免逐秒递减的 Task 停摆导致本地冷却比服务端 60s 多挡好几分钟。
    @State private var resendUntil: Date? = nil

    @State private var showRecover = false
    @State private var showLines = false
    @State private var qqSheet = false
    @State private var wxQR: APIClient.WXQR? = nil
    /// 顶部胶囊用的线路 id 镜像。`apiLineId` 存在 UserDefaults 里，**变化不会触发 SwiftUI 重绘**，
    /// 而线路半窗和「设置 → 服务器状态」页都能改它，所以这里留一份 @State，在关窗/回到前台时对齐。
    @State private var lineID: String = APIClient.activeLine.id
    @FocusState private var focused: Field?
    /// Hashable 是 `.focused($focused, equals:)` 的硬要求，也是 fieldBox 里 `focused == field` 比较的前提
    enum Field: Hashable { case email, password, code }

    private var canSubmit: Bool {
        guard agree, !busy else { return false }
        if mode == .code { return email.contains("@") && code.count == 6 }
        return email.contains("@") && password.count >= 8
    }

    private var buttonTitle: String {
        if register { return "注册并登录" }
        return mode == .code ? "验证并登录" : "登录"
    }

    /// 发送验证码按钮文案：倒计时中显示剩余秒数，禁用态与文案共用同一条件。
    private var sendCodeTitle: String {
        if busy { return "发送中" }
        if resendLeft > 0 { return "重新发送 \(resendLeft)s" }
        return "发送验证码"
    }

    /// 启动 60 秒重发冷却。保存绝对到期时刻，主线程 Task 每秒用它**重算**剩余秒数：
    /// App 切后台 Task 被挂起，回来后 `timeIntervalSinceNow` 已反映真实流逝时间，
    /// 若服务端 60s 早已过期则立刻得到 0、按钮马上可点，不会多挡几分钟。
    @MainActor
    private func startResendCountdown() {
        let until = Date().addingTimeInterval(60)
        resendUntil = until
        resendLeft = 60
        Task { @MainActor in
            while true {
                let left = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
                resendLeft = left
                if left <= 0 {
                    resendUntil = nil       // 到期清空，标识冷却结束
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    var body: some View {
        // 一屏布局：GeometryReader 量可用高度，矮屏（iPhone SE）收紧留白，
        // 绝不用 ScrollView —— 登录页不允许上下滚动。
        GeometryReader { geo in
            let compact = geo.size.height < 700

            ZStack {
                // 统一浅色底：不再有柔紫/暖橙发光圆团
                AE.paper.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focused = nil }

                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    header(compact: compact)
                        .padding(.top, compact ? 16 : 26)
                    formCard
                        .padding(.top, compact ? 14 : 20)
                    if !tip.isEmpty { tipBanner.padding(.top, 10) }
                    submitButton
                        .padding(.top, compact ? 12 : 16)
                    agreementRow
                        .padding(.top, compact ? 6 : 8)
                    Spacer(minLength: 8)
                    sectionLabel("其他登录方式")
                    thirdPartyRow
                        .padding(.top, 10)
                    recoverLink
                        .padding(.top, compact ? 8 : 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, compact ? 20 : 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .background(AE.paper.ignoresSafeArea())
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
        // 线路可能被两处改掉：本页的半窗、以及「设置 → 服务器状态」。
        // apiLineId 在 UserDefaults 里，变了不会自动触发重绘，所以这两处手动对齐胶囊。
        .onAppear { syncLineID() }
        .onChange(of: showLines) { shown in
            if !shown { syncLineID() }
        }
    }

    // MARK: - 顶部：线路入口 + 帮助（不再有发光装饰层）

    /// 胶囊文案：`线路 · 陕西 · 最快`（note 为空时退回 `线路 · 城市`）。
    /// name 是城市名（地址/base 一律不上屏）；带 note 是因为它本身有信息量（最快/默认/备用），
    /// 而且将来若出现同名城市，这一段也能帮忙区分。
    private var currentLineChipText: String {
        let line = APIClient.lines.first { $0.id == lineID } ?? APIClient.activeLine
        return line.note.isEmpty
            ? "线路 · \(line.name)"
            : "线路 · \(line.name) · \(line.note)"
    }

    /// 把 `apiLineId` 的最新值同步到胶囊（关窗后 / 回到登录页时调用）
    private func syncLineID() {
        lineID = APIClient.activeLine.id
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            // 线路入口（未登录也能用）。城市名最长 2-3 字，这里的单行缩字只是兜底。
            Button { showLines = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "location")
                        .font(.system(size: 11, weight: .medium))
                    Text(currentLineChipText)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(AE.brandInk)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AE.brandCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(LK.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("切换线路，当前 \(currentLineChipText)")
            Button("帮助") { tip = "如需帮助，请联系 aevis.cn 客服。" }
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .buttonStyle(.plain)
        }
    }

    // MARK: - 标题区（22 semibold 标题 + 13 说明，logo 不再带光晕）

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AevisMascot(size: compact ? 36 : 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(register ? "创建账号" : "登录")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AE.brandInk)
                Text(register
                     ? "设置密码后，用邮箱验证码完成注册。"
                     : "验证码会发送到你的邮箱，未注册的邮箱自动创建账号。")
                    .font(.system(size: 13))
                    .foregroundStyle(AE.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 表单卡（白卡 + 1px 描边，无阴影）

    private var formCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                emailField
                if mode == .password || register { passwordField }
                if mode == .code || register { codeRow }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // 通栏细分割线：字段组与「切换方式 / 去注册」分层（左右顶到卡片边）
            Rectangle()
                .fill(LK.hairline)
                .frame(height: 1)
                .padding(.top, 14)

            switchRow
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AE.brandCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LK.hairline, lineWidth: 1)
        )
    }

    /// 统一的输入框外壳：1px 描边 + 12 圆角 + 内底 `LK.well`，聚焦时描边变深。
    /// 不用 `.textFieldStyle(.roundedBorder)`（系统圆角+阴影，风格不统一）。
    private func fieldBox<Content: View>(
        _ field: Field?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LK.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focused == field ? LK.focusLine : LK.hairline, lineWidth: 1)
            )
    }

    private var emailField: some View {
        fieldBox(.email) {
            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .foregroundStyle(AE.textSecondary)
                    .frame(width: 18)
                TextField("邮箱地址", text: $email)
                    .font(.system(size: 16))
                    .foregroundStyle(AE.brandInk)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .focused($focused, equals: .email)
            }
        }
    }

    private var passwordField: some View {
        fieldBox(.password) {
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 14))
                    .foregroundStyle(AE.textSecondary)
                    .frame(width: 18)
                SecureField("密码（至少 8 位，含字母和数字）", text: $password)
                    .font(.system(size: 16))
                    .foregroundStyle(AE.brandInk)
                    .focused($focused, equals: .password)
            }
        }
    }

    /// 验证码行：输入框 + 次级描边按钮。倒计时/未填邮箱时按钮变灰（描边+次文字）但文字仍可读。
    private var codeRow: some View {
        let locked = busy || resendLeft > 0 || !email.contains("@")
        return HStack(spacing: 8) {
            fieldBox(.code) {
                HStack(spacing: 8) {
                    Image(systemName: "number")
                        .font(.system(size: 14))
                        .foregroundStyle(AE.textSecondary)
                        .frame(width: 18)
                    TextField("6 位验证码", text: $code)
                        .font(.system(size: 16))
                        .monospacedDigit()
                        .foregroundStyle(AE.brandInk)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .code)
                }
            }

            Button {
                // 同步置位再起 Task：disabled 到 action 之间有极小窗口，先占住 busy 防连点并发。
                guard !busy, resendLeft <= 0 else { return }
                busy = true
                Task { await sendCode() }
            } label: {
                Text(sendCodeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(locked ? AE.textSecondary : AE.brandInk)
                    .frame(width: 100, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(locked ? Color.clear : LK.well)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(LK.hairline, lineWidth: 1)
                    )
            }
            .disabled(locked)
            .buttonStyle(AevisPressStyle(scale: 0.97))
        }
    }

    private var switchRow: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    mode = (mode == .code) ? .password : .code
                    tip = ""
                }
            } label: {
                Text(mode == .code ? "用密码登录" : "用验证码登录")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AE.brandInk)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button(register ? "已有账号，去登录" : "没有账号，去注册") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    register.toggle()
                    tip = ""
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(AE.textSecondary)
            .buttonStyle(.plain)
        }
    }

    // MARK: - 提交 / 协议

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView()
                        .scaleEffect(0.85)
                        .tint(canSubmit ? Color.white : AE.textSecondary)
                }
                Text(buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(canSubmit ? Color.white : AE.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            // 12 圆角矩形（不是 Capsule），无阴影/发光
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(canSubmit ? LK.accent : AE.accentSoft)
            )
        }
        // 只按 busy 禁用：保留 submit() 里「未勾协议」的拦截提示
        .disabled(busy)
        .buttonStyle(AevisPressStyle(scale: 0.99))
    }

    /// 提示行：一行文字 + 状态图标，不再用半透明紫胶囊底
    private var tipBanner: some View {
        let isGood = tip.contains("已发送") || tip.contains("成功")
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: isGood ? "checkmark.circle" : "exclamationmark.circle")
                .font(.system(size: 13, weight: .medium))
            Text(tip)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isGood ? LK.ok : LK.bad)
    }

    private var agreementRow: some View {
        // 「勾选框点不动」的修复保留：44x44 触控区 + contentShape(Rectangle())，
        // 未勾选态也必须画出东西（描边），否则 SwiftUI 的 hit-test 会落空。
        // spacing 取负值只为抵消 44pt 盒子里勾选框两侧的空白，触控区不受影响。
        HStack(alignment: .center, spacing: -6) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { agree.toggle() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(agree ? LK.accent : Color.clear)
                        .frame(width: 18, height: 18)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(agree ? Color.clear : AE.brandInk.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if agree {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 44, height: 44)          // 满足 44pt 最小触控区
                .contentShape(Rectangle())             // 整块矩形都可点，不只认描边像素
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意用户协议和隐私政策")
            .accessibilityAddTraits(agree ? [.isSelected] : [])

            HStack(spacing: 0) {
                Text("已阅读并同意 ").foregroundStyle(AE.textSecondary)
                Link("用户协议", destination: URL(string: "https://aevis.cn/terms.html")!)
                    .foregroundStyle(AE.brandInk)
                    .underline()
                Text(" 和 ").foregroundStyle(AE.textSecondary)
                Link("隐私政策", destination: URL(string: "https://aevis.cn/privacy.html")!)
                    .foregroundStyle(AE.brandInk)
                    .underline()
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(LK.hairline).frame(height: 1)
            Text(text).font(.system(size: 12)).foregroundStyle(AE.textSecondary)
            Rectangle().fill(LK.hairline).frame(height: 1)
        }
    }

    // MARK: - 第三方登录（只放真实能跑通的入口，未实现的入口一律不出现）

    private var thirdPartyRow: some View {
        HStack(spacing: 8) {
            // 微信：`startWeChat()` 是既有真实实现（wxQRCreate → weixin:// 小程序 → wxQRPoll 轮询）
            sideButton(icon: "message", label: "微信") {
                Task { await startWeChat() }
            }
            // QQ：ASWebAuthenticationSession 走系统浏览器，服务端 302 回 aevis://login
            sideButton(icon: "bubble.left", label: "QQ") {
                qqSheet = true
            }
        }
    }

    private var recoverLink: some View {
        HStack {
            Spacer(minLength: 0)
            Button { showRecover = true } label: {
                Text("找回账号")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                    .underline(true, color: AE.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
    }

    private func sideButton(
        icon: String, label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(AE.brandInk)
            .frame(maxWidth: .infinity)
            .frame(height: 44)                     // 满足 44pt 触控高度
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AE.brandCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(LK.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(AevisPressStyle(scale: 0.98))
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
        defer { busy = false }
        do {
            try await APIClient.sendEmailCode(email: email)
            tip = "验证码已发送"
            await startResendCountdown()
        } catch {
            tip = friendly(error)
            // 服务端已在冷却中（例如刚在找回页发过）：同步本地 60 秒，避免用户狂点。
            let msg = error.localizedDescription
            if msg.contains("频繁") || msg.contains("60") {
                await startResendCountdown()
            }
        }
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
    /// 与登录页一致的 60 秒重发冷却（限流按设备+邮箱，跨页共享同一维度）
    @State private var resendLeft = 0
    /// 绝对到期时刻：切后台回来后重算剩余秒数，避免本地冷却比服务端多挡
    @State private var resendUntil: Date? = nil
    @FocusState private var emailFocused: Bool

    private var sendCodeTitle: String {
        if busy { return "发送中" }
        if resendLeft > 0 { return "重新发送 \(resendLeft)s" }
        return "发送验证码"
    }

    /// 与登录页同一套禁用条件：发送中 / 冷却中 / 邮箱还没成形
    private var locked: Bool { busy || resendLeft > 0 || !email.contains("@") }

    private var isGoodTip: Bool { tip.contains("已发送") || tip.contains("成功") }

    @MainActor
    private func startResendCountdown() {
        let until = Date().addingTimeInterval(60)
        resendUntil = until
        resendLeft = 60
        Task { @MainActor in
            while true {
                let left = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
                resendLeft = left
                if left <= 0 {
                    resendUntil = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 返回：系统 chevron（不自绘图标），44x44 触控区
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AE.brandInk)
                    .frame(width: 44, height: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")

            Text("找回账号")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AE.brandInk)
                .padding(.top, 6)
            Text("输入注册邮箱，我们会发送 6 位验证码，用来验证账号归属。")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            Text("邮箱")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AE.textSecondary)
                .padding(.top, 22)

            HStack(spacing: 8) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .foregroundStyle(AE.textSecondary)
                    .frame(width: 18)
                TextField("注册邮箱", text: $email)
                    .font(.system(size: 16))
                    .foregroundStyle(AE.brandInk)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .focused($emailFocused)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LK.well)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(emailFocused ? LK.focusLine : LK.hairline, lineWidth: 1)
            )
            .padding(.top, 8)

            Button {
                // 同步置位再起 Task，堵住 disabled 到 action 之间的连点窗口
                guard !busy, resendLeft <= 0 else { return }
                busy = true
                Task {
                    do {
                        try await APIClient.sendEmailCode(email: email)
                        tip = "验证码已发送"
                        await startResendCountdown()
                    } catch {
                        tip = error.localizedDescription
                        let msg = error.localizedDescription
                        if msg.contains("频繁") || msg.contains("60") {
                            await startResendCountdown()
                        }
                    }
                    busy = false
                }
            } label: {
                Text(sendCodeTitle)
                    .font(.system(size: 16, weight: .semibold))
                    // 冷却中：底色退成柔和中性底、文字用次色，仍然清楚可读（不是整体压暗）
                    .foregroundStyle(locked ? AE.textSecondary : Color.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(locked ? AE.accentSoft : LK.accent)
                    )
            }
            .disabled(locked)
            .buttonStyle(AevisPressStyle(scale: 0.99))
            .padding(.top, 14)

            if !tip.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isGoodTip ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text(tip)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isGoodTip ? LK.ok : LK.bad)
                .padding(.top, 12)
            }

            Spacer(minLength: 12)

            Text("60 秒内只能发送一次。没收到请检查垃圾邮件，或稍后重试。")
                .font(.system(size: 12))
                .foregroundStyle(AE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .background(AE.paper.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - 扫码登录（服务端给 image_url，微信唤不起时用它兜底）

/// SwiftUI 的 `.sheet(item:)` 需要一个 Identifiable 包装
struct WXItem: Identifiable {
    let id = UUID()
    let info: APIClient.WXQR
}

/// 微信扫码兜底半窗（只在「唤起微信失败」时出现，不是一个独立入口）。
/// 信息层级对齐网页版 `assets/qrlogin.js` 的 `.aql-card`：
/// 标题 + 说明（logo 在前）→ 208pt 二维码（1px 描边白框）→ 状态一行 → 主按钮 → 取消。
struct WxQRView: View {
    @Environment(\.dismiss) private var dismiss
    let info: APIClient.WXQR
    var onToken: (String) -> Void

    @State private var status = "等待微信里确认…（最长 180 秒）"
    @State private var expired = false
    @State private var cancelled = false

    private var imageURL: URL? {
        guard !info.imageURL.isEmpty else { return nil }
        if info.imageURL.hasPrefix("http") { return URL(string: info.imageURL) }
        return URL(string: APIClient.base + info.imageURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题区：logo 40 + 标题 17 semibold + 说明 12.5（网页版 aql-hd 的层级）
            HStack(spacing: 12) {
                AevisMascot(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("扫码登录")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.brandInk)
                    Text("用微信扫一扫，在手机上确认后自动登录。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // 二维码：208pt 白框 + 1px 描边 + 11pt 内衬（对齐网页版 .aql-qr）
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AE.brandCard)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(LK.hairline, lineWidth: 1)
                if let u = imageURL {
                    AsyncImage(url: u) { img in
                        img.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        ProgressView().tint(AE.textSecondary)
                    }
                    .padding(11)
                } else {
                    Text("二维码暂不可用，请重试")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
            }
            .frame(width: 208, height: 208)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)

            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(expired ? LK.bad : AE.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

            Button { openWeChat() } label: {
                Text("打开微信")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LK.accent)
                    )
            }
            .buttonStyle(AevisPressStyle(scale: 0.99))
            .padding(.top, 20)

            Button {
                cancelled = true
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 14))
                    .foregroundStyle(AE.textSecondary)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .background(AE.paper.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await poll(ticket: info.ticket) }
    }

    private func openWeChat() {
        guard let u = URL(string: "weixin://") else { return }
        if UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else {
            status = "未安装微信，请用其它方式扫码"
        }
    }

    @MainActor
    private func poll(ticket: String) async {
        let deadline = Date().addingTimeInterval(180)
        while !cancelled && Date() < deadline {
            if let token = (try? await APIClient.wxQRPoll(ticket: ticket)) ?? nil {
                status = "登录成功"
                onToken(token)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if !cancelled {
            expired = true
            status = "二维码已过期，请重新点「微信」"
        }
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
        VStack(spacing: 0) {
            Text("QQ 登录")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AE.brandInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("将打开系统浏览器完成 QQ 授权，完成后自动回到 Aevis。")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            if !tip.isEmpty {
                Text(tip)
                    .font(.system(size: 13))
                    .foregroundStyle(AE.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            }
            Spacer(minLength: 4)
            Button("取消") { dismiss() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AE.brandInk)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AE.brandCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(LK.hairline, lineWidth: 1)
                )
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .background(AE.paper.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
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

// MARK: - 线路选择
//
// 行内容：名称 + 当前延迟 + 选中标记。name 是城市名（地址/base 一律不上屏）；
// 会同时存在两条同名城市（北京/北京、香港/香港），靠名字下面的 note（最快/默认/备用）区分。
// 点一行立即切换并关窗；当前生效线路用「对勾 + 深描边」双标记，不只靠颜色区分。
//
// 延迟：每行自己 `.task { await APIClient.lineLatency(line) }`，
// 四条并发、谁先回来谁先替换「测速中…」，不阻塞 sheet 展开。
// 失败行会带上本地实测耗时：真超时「超时 · 3000 ms」，几百毫秒就失败「连接失败 · 180 ms」。
// 上色按毫秒值分四档（`latencyColor(_:)`，数字与圆点共用）：
//   ≤80 绿 / 80–200 黄绿 / 200–500 橙 / >500 红；超时、连接失败整段红。

struct LineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var active: String = APIClient.activeLine.id
    @State private var lineTip = ""

    var body: some View {
        ZStack {
            GlassBackdrop()
            // 小屏（SE，medium 高度约 333pt）放不下 4 行时允许滚动，内容够高就不滚
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("线路")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AE.brandInk)
                    Text("点一下切换；行尾是这个线路的当前延迟。")
                        .font(.system(size: 13))
                        .foregroundStyle(AE.textSecondary)
                        .padding(.top, 5)

                    VStack(spacing: 8) {
                        ForEach(APIClient.lines) { line in
                            lineRow(line)
                        }
                    }
                    .padding(.top, 16)

                    if !lineTip.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 12, weight: .medium))
                            Text(lineTip)
                                .font(.system(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(LK.bad)
                        .padding(.top, 10)
                    }

                    Text("连不上会自动重试其它线路。")
                        .font(.system(size: 12))
                        .foregroundStyle(AE.textSecondary)
                        .padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        // `.presentationBackground` 是 16.4+，走工程里的兼容包装，禁止裸调用
        .glassSheetBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 单行

    private func lineRow(_ line: APIClient.Line) -> some View {
        LineRowView(
            line: line,
            selected: active == line.id && !line.base.isEmpty
        ) {
            // 坏线路（base 空 = 实测 404 / 自签 SSL 失败）不让选中，给明确提示。
            // 不再拼 line.note：note 现在是「最快 / 默认」这类短词，接在「暂不可用：」后面不通顺。
            guard !line.base.isEmpty else {
                lineTip = "「\(line.name)」暂时连不上，请换一条。"
                return
            }
            lineTip = ""
            APIClient.setActiveLine(line.id)
            active = line.id
            dismiss()            // 点一行即生效并关窗
        }
    }
}

/// 单条线路行。
///
/// 测速放在行内 `.task` 里：四条线各自并发，谁先回来谁先替换「测速中…」，
/// sheet 展开不等网络；行消失（关窗）时 task 自动取消，不会泄漏请求。
/// 名称是城市名，地址（base/IP）一律不上屏。
private struct LineRowView: View {
    let line: APIClient.Line
    let selected: Bool
    let onTap: () -> Void

    /// 接口返回的毫秒；nil 可能是「还没测完」也可能是「超时/不可用」，用 `finished` 区分
    @State private var ms: Int?
    /// 本地实测耗时（毫秒）。超时时接口只给 nil，用它把「等了多久」显示出来
    @State private var elapsed = 0
    @State private var finished = false

    private var unavailable: Bool { line.base.isEmpty }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // 质量小圆点：与右侧毫秒文字同色（四档：绿/黄绿/橙/红），
                // 测速中与不可用为灰（见 dotColor / latencyColor）
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    // 城市名很短，单行缩字只是兜底（将来名字变长也不会撑破行）
                    Text(line.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.brandInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !line.note.isEmpty {
                        Text(line.note)
                            .font(.system(size: 11))
                            .foregroundStyle(AE.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                // 延迟：等宽数字，避免逐行跳动时宽度乱颤。
                // 「32 ms」这几个字本身按毫秒分档上色（不是只有圆点变色），
                // 超时/连接失败态是红字，比「32 ms」长，单行 + 高优先级保证不被名字挤掉。
                Text(latencyText)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(currentLatencyColor)
                    .lineLimit(1)
                    .layoutPriority(1)

                // 选中标记：对勾（不只靠颜色）
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.brandInk)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 16)
            }
            .padding(.horizontal, 14)
            .frame(height: 54)                       // 52-56pt 行高
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassCard(
            cornerRadius: 14,
            material: .thin,
            strokeColor: selected ? AE.brandInk : .white,
            strokeOpacity: selected ? 0.55 : 0.22
        )
        .opacity(unavailable ? 0.6 : 1)
        .task { await measure() }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - 文案

    private var latencyText: String {
        if unavailable && finished { return "不可用" }
        guard finished else { return "测速中…" }
        if let value = ms { return "\(value) ms" }
        // nil 有两种成因，分开说，别让用户看到「超时 · 180 ms」这种自相矛盾的文案：
        //   elapsed 接近接口 3s 超时 → 真超时；几百毫秒就失败 → 证书/TLS 之类直接失败。
        return elapsed >= 2500 ? "超时 · \(elapsed) ms" : "连接失败 · \(elapsed) ms"
    }

    /// 延迟分档配色（用户要求「按 ms 加颜色」）：数字文字与左侧小圆点**共用这一套**，
    /// 阈值只在这里出现一次，别在别处再写判断。
    ///   ≤80ms 绿 / 80–200ms 黄绿 / 200–500ms 橙 / >500ms 红 —— 四档，不做彩虹渐变。
    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ...80:    return LK.ok
        case 81...200: return LK.lime
        case 201...500: return LK.warn
        default:       return LK.bad
        }
    }

    /// 「32 ms」这段文字本身的颜色（不是只有圆点变色）
    private var currentLatencyColor: Color {
        // 测速中 / 不可用：次色，不参与分档
        guard finished, !unavailable else { return AE.textSecondary }
        if let value = ms { return latencyColor(value) }
        // 超时 / 连接失败：整段红字（与 >500ms 同档）
        return LK.bad
    }

    /// 左侧小圆点：有毫秒值时和文字同色，剩下两种灰（测速中略淡）
    private var dotColor: Color {
        guard finished else { return AE.textSecondary.opacity(0.35) }
        if unavailable { return AE.textSecondary.opacity(0.3) }
        if let value = ms { return latencyColor(value) }
        return LK.bad
    }

    private var accessibilityText: String {
        var parts = [line.name, latencyText]
        if selected { parts.append("当前线路") }
        return parts.joined(separator: "，")
    }

    // MARK: - 测速

    /// 本地也计一次时：接口超时只会返回 nil，光写「超时」看不出等了多久，
    /// 所以把 `Date()` 差值一起存下来，超时行显示「超时 · 3000 ms」。
    @MainActor
    private func measure() async {
        let start = Date()
        let value = await APIClient.lineLatency(line)
        let cost = Int(Date().timeIntervalSince(start) * 1000)
        ms = value
        elapsed = cost
        finished = true
    }
}
