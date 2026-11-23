import SwiftUI

/// 注册页（独立全屏页，从登录页「去注册」跳入）。
///
/// ## 设计要点
/// - 全屏页面（不是半窗），顶部有返回按钮
/// - 表单：邮箱 + 密码 + 验证码（三个字段必填）
/// - 协议勾选：与登录页一致
/// - 注册成功后自动登录并返回
///
/// ## 字段
/// - 邮箱：验证码和密码登录共用
/// - 密码：至少 8 位，含字母和数字
/// - 验证码：6 位数字，点按钮发送到邮箱
struct RegisterView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var agree = false
    @State private var busy = false
    @State private var tip = ""
    @State private var resendLeft = 0
    @State private var resendUntil: Date? = nil
    @State private var showTerms = false
    @State private var showPrivacy = false
    @FocusState private var focused: Field?
    
    enum Field: Hashable { case email, password, code }
    
    private var canSubmit: Bool {
        agree && !busy && email.contains("@") && password.count >= 8 && code.count == 6
    }
    
    private var sendCodeTitle: String {
        if busy { return "发送中" }
        if resendLeft > 0 { return "重新发送 \(resendLeft)s" }
        return "发送验证码"
    }
    
    private var locked: Bool { busy || resendLeft > 0 || !email.contains("@") }
    
    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            
            ZStack {
                Color.paper.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focused = nil }
                
                VStack(alignment: .leading, spacing: 0) {
                    // 返回按钮
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AE.brandInk)
                            .frame(width: 44, height: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回")
                    
                    // 标题
                    Text("创建账号")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AE.brandInk)
                        .padding(.top, 6)
                    
                    Text("设置密码后，用邮箱验证码完成注册。")
                        .font(.system(size: 13))
                        .foregroundStyle(AE.textSecondary)
                        .lineSpacing(2)
                        .padding(.top, 6)
                    
                    // 表单卡
                    formCard
                        .padding(.top, compact ? 14 : 20)
                    
                    if !tip.isEmpty { tipBanner.padding(.top, 10) }
                    
                    submitButton
                        .padding(.top, compact ? 12 : 16)
                    
                    agreementRow
                        .padding(.top, compact ? 6 : 8)
                    
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, compact ? 20 : 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .sheet(isPresented: $showTerms) {
            AgreementWebView(name: .terms)
        }
        .sheet(isPresented: $showPrivacy) {
            AgreementWebView(name: .privacy)
        }
    }
    
    // MARK: - 表单卡
    
    private var formCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                emailField
                passwordField
                codeRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AE.brandCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LK.hairline, lineWidth: 1)
        )
    }
    
    private func fieldBox(_ field: Field?, @ViewBuilder content: () -> some View) -> some View {
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
    
    private var codeRow: some View {
        HStack(spacing: 8) {
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
    
    // MARK: - 提交
    
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
                Text("注册并登录")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(canSubmit ? Color.white : AE.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(canSubmit ? LK.accent : AE.accentSoft)
            )
        }
        .disabled(busy)
        .buttonStyle(AevisPressStyle(scale: 0.99))
    }
    
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
    
    // MARK: - 协议
    
    private var agreementRow: some View {
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
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("同意用户协议和隐私政策")
            .accessibilityAddTraits(agree ? [.isSelected] : [])
            
            HStack(spacing: 0) {
                Text("已阅读并同意 ").foregroundStyle(AE.textSecondary)
                Button { showTerms = true } label: {
                    Text("用户协议").underline()
                }
                .foregroundStyle(AE.brandInk)
                Text(" 和 ").foregroundStyle(AE.textSecondary)
                Button { showPrivacy = true } label: {
                    Text("隐私政策").underline()
                }
                .foregroundStyle(AE.brandInk)
            }
            .font(.system(size: 13))
            .fixedSize(horizontal: false, vertical: true)
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - 行为
    
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
            let r = try await APIClient.register(email: email, password: password, code: code)
            await session.applyLogin(token: r.token, email: email)
            dismiss() // 注册成功返回登录页（已登录态会自动跳主页）
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

// MARK: - 协议 WebView（显示本地缓存或云端内容）

struct AgreementWebView: View {
    @Environment(\.dismiss) private var dismiss
    let name: AgreementContentStore.Name
    
    @StateObject private var store = AgreementContentStore.shared
    @State private var content: String = ""
    @State private var isRefreshing = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                Text(attributedContent)
                    .font(.system(size: 14))
                    .foregroundStyle(AE.brandInk)
                    .padding(16)
            }
            .background(Color.paper.ignoresSafeArea())
            .navigationTitle(name.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(AE.brandInk)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .foregroundStyle(AE.brandInk)
                    }
                }
            }
        }
        .onAppear { loadContent() }
    }
    
    private var attributedContent: AttributedString {
        // 简单处理：直接显示 HTML 内容
        // 实际项目中可以用 WKWebView 或 Markdown 解析
        // 这里为了 iOS 16 兼容，用纯文本显示
        let html = content
        // 移除 HTML 标签（粗略处理）
        let text = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        
        return AttributedString(text)
    }
    
    private func loadContent() {
        content = store.content(name)
    }
    
    private func refresh() async {
        isRefreshing = true
        await store.refresh(name)
        loadContent()
        isRefreshing = false
    }
}
