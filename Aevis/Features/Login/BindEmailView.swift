// 绑定邮箱（2026-11-12）
//
// 用户：「检测登录成功了，就是有微信登录，但是没有那个绑定邮箱，
//       再让他们绑定一下邮箱」。
//
// 微信登录只能证明"你是这个微信"，换台手机就找不回来了。所以这个号
// 在补齐真邮箱之前，先停在这一页：不绑不让进主界面，左下角留了退出登录。
//
// 服务端对应：`POST /v1/auth/email/bind { email, code }`
//   · 首次绑定只要新邮箱验证码（换绑才要原邮箱那枚）；
//   · 绑成功后服务端会把 `wx:<uid>` 那套数据迁到这个邮箱上。
import SwiftUI

struct BindEmailView: View {
    @EnvironmentObject private var account: AccountService

    @State private var email = ""
    @State private var code = ""
    @State private var counting = 0
    @State private var sending = false
    @State private var submitting = false
    @State private var note: String?
    @State private var showQuit = false
    @State private var timer: Timer?

    private var emailOK: Bool {
        let t = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("@") && t.contains(".") && t.count >= 5
    }
    private var canSubmit: Bool { emailOK && code.count == 6 && !submitting }

    var body: some View {
        ZStack {
            V2.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    header
                    card
                    tip
                    quitButton
                }
                .padding(.horizontal, V2.gutter)
                .padding(.top, 40)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onDisappear { timer?.invalidate(); timer = nil }
        .confirmationDialog("退出登录？", isPresented: $showQuit, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { account.signOut() }
            Button("继续绑定", role: .cancel) {}
        } message: {
            Text("不绑邮箱也能用，但这个号以后换手机就找不回来了。")
        }
    }

    // MARK: - 版块

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(V2.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(V2.stroke, lineWidth: 0.5)
                    )
                    .frame(width: 76, height: 76)
                Image(systemName: "envelope.badge")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(V2.accent)
            }

            Text("还差一步")
                .font(.aevis(23, weight: .semibold))

            Text("微信只说明「你是这个微信」。邮箱才是账号凭证 —— 换手机、找回账号都靠它。")
                .font(.aevis(12.5))
                .foregroundStyle(V2.dim(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }

    private var card: some View {
        VStack(spacing: 12) {
            TextField("输入邮箱", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .font(.aevis(15))
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            HStack(spacing: 8) {
                TextField("6 位验证码", text: $code)
                    .keyboardType(.numberPad)
                    .font(.aevis(15))
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(V2.well, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .onChange(of: code) { _, v in
                        let digits = String(v.filter { $0.isNumber }.prefix(6))
                        if digits != v { code = digits }
                    }

                Button {
                    sendCode()
                } label: {
                    Text(counting > 0 ? "\(counting)s" : (sending ? "发送中" : "发送验证码"))
                        .font(.aevis(12.5, weight: .medium))
                        .foregroundStyle(counting > 0 ? V2.dim(0.4) : V2.accent)
                        .frame(width: 92, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(counting > 0 ? V2.well : V2.soft(0.14))
                        )
                }
                .disabled(counting > 0 || sending)
                .buttonStyle(.plain)
            }

            Button {
                submit()
            } label: {
                Text(submitting ? "绑定中…" : "绑定并继续")
                    .font(.aevis(16, weight: .medium))
                    .foregroundStyle(canSubmit ? .white : V2.dim(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        Capsule(style: .continuous)
                            .fill(canSubmit ? V2.accent : V2.well)
                    )
            }
            .disabled(!canSubmit)
            .buttonStyle(.plain)
            .padding(.top, 4)

            if let note {
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(V2.alert)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(V2.card, in: RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: V2.cardRadius, style: .continuous)
                .stroke(V2.stroke, lineWidth: 0.5)
        )
    }

    private var tip: some View {
        Text("绑好之后，这个邮箱就是你的登录账号：App、小程序都能用它登。")
            .font(.aevis(11.5))
            .foregroundStyle(V2.dim(0.42))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
    }

    private var quitButton: some View {
        Button("先不绑，退出登录") { showQuit = true }
            .font(.aevis(13))
            .foregroundStyle(V2.dim(0.5))
            .buttonStyle(.plain)
            .padding(.top, 8)
    }

    // MARK: - 动作

    private func sendCode() {
        guard emailOK, !sending, counting == 0 else {
            note = "先填一个能收信的邮箱"
            return
        }
        sending = true
        note = nil
        Task {
            do {
                try await account.requestRegisterCode(email: email)
                await MainActor.run {
                    sending = false
                    counting = 60
                    startTimer()
                }
            } catch {
                await MainActor.run {
                    sending = false
                    note = error.localizedDescription
                }
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if counting <= 1 {
                t.invalidate()
                counting = 0
            } else {
                counting -= 1
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        note = nil
        Task {
            do {
                try await account.bindEmail(email, code: code)
                await MainActor.run { submitting = false }
            } catch {
                await MainActor.run {
                    submitting = false
                    note = error.localizedDescription
                }
            }
        }
    }
}
