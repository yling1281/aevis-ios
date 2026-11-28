import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// QQ 接入（2026-11-28 第二次纠正：绑的是**用户自己的机器人**）。
///
/// 用户原话：「是要绑定用户自己的机器人啊…QQ 扫完码会提示这是一个什么 QQ 机器人，
/// 需要你自己去绑定，绑定你的哪个机器人」——
///
///   1. 二维码内容是 QQ 官方 OpenClaw 扫码入口（q.qq.com），不是自建落地页；
///   2. 扫码后在 QQ 里登录开放平台，创建/选择属于他自己的机器人；
///   3. 页面直接给出这个机器人的 AppID / AppSecret，复制回 App 填；
///   4. 服务端校验后按这份凭据单开一条 Bot 连接 —— 机器人是他的，人设挂他的账号。
///
/// 一个账号只能绑一个机器人；换绑要先解绑。
struct QQBindView: View {
    @EnvironmentObject private var session: Session

    private static let stageScan = 0
    private static let stageCred = 1
    private static let stageBound = 2

    @State private var enabled = true
    @State private var stage = 0

    @State private var officialURL = ""
    @State private var officialQR: UIImage?

    @State private var appid = ""
    @State private var botName = ""
    @State private var linkState = ""

    @State private var appidIn = ""
    @State private var secretIn = ""
    @State private var showSecret = false

    @State private var busy = false
    @State private var err = ""

    @State private var personas: [Persona] = []
    @State private var persona = ""
    @State private var stateTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !enabled {
                    emptyCard("QQ 接入暂未开放", "后台打开开关后这里就能用")
                } else {
                    stepBar
                    mainCard
                    if !err.isEmpty {
                        Text(err).font(.system(size: 12.5)).foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                    actionButton
                    if stage != Self.stageBound { personaSection }
                    if stage == Self.stageBound { unbindRow }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("QQ 接入")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { stateTask?.cancel() }
    }

    // MARK: - 步骤条

    private var stepBar: some View {
        let labels = ["扫码", "填密钥", "完成"]
        return HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                let done = stage > i
                let cur = stage == i
                ZStack {
                    Circle()
                        .fill(done ? AE.accentDeep
                              : (cur ? AE.accent.opacity(0.18) : AE.textSecondary.opacity(0.12)))
                        .frame(width: 18, height: 18)
                    Text(done ? "✓" : "\(i + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(done ? .white
                                         : (cur ? AE.accent : AE.textSecondary.opacity(0.7)))
                }
                Text(t)
                    .font(.system(size: 11))
                    .foregroundStyle(cur ? AE.accent : AE.textSecondary.opacity(done ? 0.85 : 0.6))
                if i < labels.count - 1 {
                    Rectangle()
                        .fill(AE.textSecondary.opacity(0.18))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - 主卡

    private var mainCard: some View {
        VStack(spacing: 10) {
            if stage == Self.stageScan {
                Text("第 1 步 · 用手机 QQ 扫这个码")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Text("扫码后登录 QQ 开放平台，创建或选择你自己的机器人")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                    .multilineTextAlignment(.center)

                if let img = officialQR {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 190, height: 190)
                        .padding(10)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    ProgressView().frame(height: 190)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("1. 手机 QQ 扫码，登录 QQ 开放平台")
                    Text("2. 点「创建机器人」，或用你已经有的那个")
                    Text("3. 复制页面上这个机器人的 AppID 和 AppSecret")
                    Text("4. 回来点「我复制好了」，填进来就绑上了")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            } else if stage == Self.stageCred {
                Text("第 2 步 · 填你自己机器人的凭据")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Text("在开放平台那个机器人的「开发设置」里能看到")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 10) {
                    field("AppID", text: $appidIn, placeholder: "纯数字，例如 1905697056", numeric: true)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("AppSecret")
                                .font(.system(size: 11.5))
                                .foregroundStyle(AE.textSecondary)
                            Spacer()
                            Button(showSecret ? "隐藏" : "显示") { showSecret.toggle() }
                                .font(.system(size: 11.5))
                                .foregroundStyle(AE.accent)
                        }
                        Group {
                            if showSecret {
                                TextField("32 位字符串", text: $secretIn)
                            } else {
                                SecureField("32 位字符串", text: $secretIn)
                            }
                        }
                        .font(.system(size: 13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(AE.textSecondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    Text("密钥只存服务端、只写不读，后台和 App 都不会回显")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AE.textSecondary.opacity(0.7))
                }
                .padding(.top, 4)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.hex(0x34C759))
                Text("已绑定你的机器人")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AE.accent)
                if !botName.isEmpty {
                    Text(botName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                }
                if !appid.isEmpty {
                    Text("AppID \(appid)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary.opacity(0.8))
                }
                Text(linkText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(linkColor)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(AE.card)
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous))
    }

    private func field(_ label: String, text: Binding<String>,
                       placeholder: String, numeric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(AE.textSecondary)
            TextField(placeholder, text: text)
                .font(.system(size: 13))
                .keyboardType(numeric ? .numberPad : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(AE.textSecondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var linkText: String {
        switch linkState {
        case "online": return "连接正常，可以在 QQ 里直接聊"
        case "error": return "连接异常，检查密钥或开放平台 IP 白名单"
        case "pending", "": return "正在连接…"
        default: return linkState
        }
    }

    private var linkColor: Color {
        switch linkState {
        case "online": return Color.hex(0x34C759)
        case "error": return .red
        default: return AE.textSecondary
        }
    }

    private func emptyCard(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 14)).foregroundStyle(AE.textPrimary)
            Text(sub).font(.system(size: 12)).foregroundStyle(AE.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(AE.card)
        .clipShape(RoundedRectangle(cornerRadius: AE.cardRadius, style: .continuous))
    }

    // MARK: - 主按钮

    private var canGo: Bool {
        if busy { return false }
        if stage == Self.stageCred { return appidIn.count >= 5 && secretIn.count >= 16 }
        return true
    }

    private var actionButton: some View {
        Button {
            Task { await primaryAction() }
        } label: {
            Text(busy ? "请稍候…"
                 : (stage == Self.stageScan ? "我复制好了，去填"
                    : (stage == Self.stageCred ? "绑定这个机器人" : "换绑机器人")))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(canGo ? Color.white : AE.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(canGo ? AE.accentDeep : AE.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canGo)
    }

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QQ 里用哪个人设回你")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(AE.textSecondary)
            if personas.isEmpty {
                Text("还没有人设，先去通讯录加一个")
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary.opacity(0.8))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(personas.prefix(20)) { p in
                            let on = p.id == persona
                            Button { persona = p.id } label: {
                                VStack(spacing: 4) {
                                    Circle()
                                        .fill(AE.accent.opacity(0.15))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Text(String(p.name.prefix(1)))
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(AE.accent)
                                        )
                                        .overlay(Circle().stroke(on ? AE.accent : .clear, lineWidth: 2))
                                    Text(p.name)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(on ? AE.accent : AE.textSecondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 56)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, 2)
    }

    private var unbindRow: some View {
        Button {
            Task { await doUnbind() }
        } label: {
            Text("解除绑定")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func primaryAction() async {
        switch stage {
        case Self.stageBound:
            await doUnbind()
        case Self.stageScan:
            err = ""
            stage = Self.stageCred
            if officialURL.isEmpty { await loadEntry() }
        default:
            await bindCred()
        }
    }

    private func load() async {
        guard let token = session.token, !token.isEmpty else {
            err = "未登录"
            return
        }
        if let j = try? await APIClient.request("/v1/qqbot/status", token: token),
           let d = j["data"] as? [String: Any] {
            enabled = (d["enabled"] as? Bool) ?? true
            officialURL = (d["official_url"] as? String) ?? ""
            appid = (d["appid"] as? String) ?? ""
            botName = (d["bot_name"] as? String) ?? ""
            linkState = (d["state"] as? String) ?? ""
            persona = (d["persona"] as? String) ?? ""
            let mine = (d["bound_mine"] as? Bool) ?? false
            let bound = (d["bound"] as? Bool) ?? false
            stage = (mine || (bound && !appid.isEmpty)) ? Self.stageBound : Self.stageScan
        }
        if let list = try? await APIClient.myPersonas(token: token, email: session.email) {
            personas = list
            if persona.isEmpty, let f = list.first { persona = f.id }
        }
        if stage != Self.stageBound && enabled {
            await loadEntry()
        }
        if stage == Self.stageBound { startStatePolling() }
    }

    /// 拿官方扫码入口（内容就是 q.qq.com 的 OpenClaw 页面），本地画二维码。
    private func loadEntry() async {
        guard let token = session.token else { return }
        if officialURL.isEmpty {
            if let j = try? await APIClient.request("/v1/qqbot/bind/start", method: "POST",
                                                    body: ["persona": persona], token: token),
               let d = j["data"] as? [String: Any] {
                officialURL = (d["official_url"] as? String) ?? (d["url"] as? String) ?? ""
            }
        }
        if officialURL.isEmpty {
            officialURL = "https://q.qq.com/qqbot/openclaw/login.html"
        }
        officialQR = makeQR(officialURL)
    }

    private func bindCred() async {
        guard let token = session.token else { return }
        busy = true
        err = ""
        let body: [String: Any] = [
            "appid": appidIn.trimmingCharacters(in: .whitespacesAndNewlines),
            "secret": secretIn.trimmingCharacters(in: .whitespacesAndNewlines),
            "persona": persona
        ]
        let j = try? await APIClient.request("/v1/qqbot/bind/cred", method: "POST",
                                             body: body, token: token)
        busy = false
        if let j, (j["code"] as? Int ?? 1) == 0, let d = j["data"] as? [String: Any] {
            appid = (d["appid"] as? String) ?? appidIn
            botName = (d["bot_name"] as? String) ?? ""
            linkState = (d["state"] as? String) ?? "pending"
            secretIn = ""
            stage = Self.stageBound
            startStatePolling()
        } else {
            err = errorText(j) ?? "绑定失败，检查 AppID / AppSecret"
        }
    }

    /// 绑完等服务端把连接建起来：pending → online / error。
    private func startStatePolling() {
        stateTask?.cancel()
        guard let token = session.token else { return }
        stateTask = Task {
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let j = try? await APIClient.request("/v1/qqbot/status", token: token),
                      let d = j["data"] as? [String: Any] else { continue }
                let st = (d["state"] as? String) ?? ""
                await MainActor.run {
                    linkState = st
                    botName = (d["bot_name"] as? String) ?? botName
                }
                if st == "online" || st == "error" { return }
            }
        }
    }

    private func doUnbind() async {
        guard let token = session.token else { return }
        busy = true
        _ = try? await APIClient.request("/v1/qqbot/unbind", method: "POST",
                                         body: [:], token: token)
        busy = false
        stateTask?.cancel()
        stage = Self.stageScan
        appid = ""
        botName = ""
        linkState = ""
        appidIn = ""
        secretIn = ""
        err = ""
    }

    // MARK: - 工具

    private func errorText(_ j: [String: Any]?) -> String? {
        guard let j else { return nil }
        let m = (j["msg"] as? String) ?? ""
        return m.isEmpty ? nil : m
    }

    private func makeQR(_ text: String) -> UIImage? {
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let out = filter.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
