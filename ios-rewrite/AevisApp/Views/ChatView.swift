import SwiftUI
import AVFoundation

/// 聊天（2026-11-17 骨架；2026-11-22 升级为流式 SSE）。
///
/// 本地历史能看、能发、括号变浅、头像/字号跟设置；回复走 SSE 逐字显示，
/// 增量到达即刷新气泡并滚动贴底；网络/格式异常有兜底与「重发」。
struct ChatView: View {
    @EnvironmentObject private var session: Session
    let persona: Persona
    #if DEBUG
    /// 137：CI 截图用的样例模式（不读写本地、不发请求）。Release 编不进去。
    var demo: Bool = false
    #endif

    @State private var msgs: [Msg] = []
    @State private var input = ""
    @State private var sending = false
    @State private var error = ""
    /// 错误分类：决定错误条右侧给什么动作（重新登录 / 去充值 / 重发）。
    @State private var errorKind: ErrorKind = .none
    /// 流式时 msgs.count 不变、content 变，靠这个 tick 触发滚动贴底。
    @State private var scrollTick = 0

    enum ErrorKind { case none, relogin, recharge, retry }

    @AppStorage("msgSize") private var msgSize = 1          // 0 小 / 1 标准 / 2 大
    @AppStorage("annotDim") private var annotDim = true
    @AppStorage("avatarMode") private var avatarMode = 0    // 0 双方 / 1 只角色 / 2 都不显示

    // MARK: - 每角色配置（模型/温度）：发送时读，UI 编辑在 CharacterSettingsView
    /// 该角色选择的模型 id；空 = 用服务端默认。按 persona.id 独立存（UserDefaults）。
    @State private var selectedModelID: String = ""
    @State private var modelDefaultID: String = "deepseek-flash"
    /// 该角色的温度（0.0–2.0，默认 1.0），按角色存。
    @State private var temperature: Double = 1.0

    /// 表情包面板（最小可用：静态占位说明，不做上传）。
    @State private var showStickerSheet = false
    /// 是否正在朗读。
    @State private var speaking = false

    /// 每角色独立的 UserDefaults key。
    private var modelKey: String { "aevisModel_\(persona.id)" }
    private var tempKey: String { "aevisTemp_\(persona.id)" }

    /// 发送时实际使用的模型 id：角色选过就用，否则用服务端默认，最后兜底 deepseek-flash。
    private var modelForPersona: String {
        let chosen = selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !chosen.isEmpty { return chosen }
        return modelDefaultID.isEmpty ? "deepseek-flash" : modelDefaultID
    }

    /// 三档字号（与安卓 msgSize 一致；行高 = ×1.45）
    private var fontSize: CGFloat { AE.chatFont(msgSize) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(msgs) { m in
                            row(m).id(m.id)
                        }
                        if sending {
                            HStack {
                                Text("正在输入…").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: msgs.count) { _ in
                    if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                .onChange(of: scrollTick) { _ in
                    if let last = msgs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            if !error.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: errorIcon)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(error).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actionButton
                }
                .padding(.horizontal, 14)
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                // 左：表情包面板（最小可用：静态占位）
                Button { showStickerSheet = true } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 22))
                        .foregroundStyle(AE.accent)
                }
                .accessibilityLabel("表情包")

                TextField("说点什么…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                // 右：朗读最近一条助手回复（本地 TTS）
                Button { toggleSpeakLastReply() } label: {
                    Image(systemName: speaking ? "stop.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(hasAssistantReply ? AE.accent : AE.textSecondary.opacity(0.4))
                }
                .disabled(!hasAssistantReply)
                .accessibilityLabel(speaking ? "停止朗读" : "朗读")

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(.regularMaterial)
        }
        .navigationTitle(persona.name)
        .navigationBarTitleDisplayMode(.inline)
        // 进聊天详情时收起底部 Dock：系统原生 tab bar 在 push 时不会自动隐藏，
        // 必须由被 push 的目的页声明；加在 ChatListView / 外层会把列表根页的 Dock 也藏掉。
        .toolbar(.hidden, for: .tabBar)
        // 右上角：进入「角色设置」（模型选择等已挪到那里，聊天页不再放 cpu 按钮）
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    CharacterSettingsView(persona: persona)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
                .accessibilityLabel("角色设置")
            }
        }
        .sheet(isPresented: $showStickerSheet) { stickerSheet }
        .onAppear { reloadPersonaConfig() }
        .task {
            #if DEBUG
            if demo {
                msgs = [
                    Msg(role: "user", content: "在吗"),
                    Msg(role: "assistant", content: "（她抬眼看你）在的，刚泡了杯茶。今天想聊点什么？"),
                    Msg(role: "user", content: "随便聊聊，今天有点累"),
                    Msg(role: "assistant", content: "那就别硬撑了。（把椅子往你这边挪了挪）先说说，是身体累还是心里累？")
                ]
            } else {
                msgs = LocalStore.load(pid: persona.id)
            }
            #else
            msgs = LocalStore.load(pid: persona.id)
            #endif
            reloadPersonaConfig()
        }
    }

    // MARK: - 每角色配置读取

    /// 从 UserDefaults 读该角色选的模型与温度（角色设置页保存后返回会重新触发）。
    @MainActor
    private func reloadPersonaConfig() {
        selectedModelID = UserDefaults.standard.string(forKey: modelKey) ?? ""
        // 温度：没存过用 1.0（object 判空，避免把 0 当成未设置）
        if let t = UserDefaults.standard.object(forKey: tempKey) as? Double {
            temperature = t
        } else {
            temperature = 1.0
        }
        // 拉一次模型默认值（公开接口，失败就用 deepseek-flash 兜底，不阻塞聊天）
        Task {
            if let list = try? await APIClient.llmModels() {
                await MainActor.run { modelDefaultID = list.defaultID }
            }
        }
    }

    // MARK: - 朗读（本地 TTS，无网络无权限）

    /// 是否存在可朗读的助手回复（决定语音按钮是否可点）。
    private var hasAssistantReply: Bool {
        msgs.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) != nil
    }

    /// 朗读最近一条助手回复；正在朗读则停止（再点一下停止）。
    private func toggleSpeakLastReply() {
        if speaking {
            ChatTTS.shared.stop()
            speaking = false
            return
        }
        guard let reply = msgs.last(where: { $0.role == "assistant" && !$0.content.isEmpty }) else { return }
        // 括号里的动作描写（（xxx）/ (xxx)）朗读时去掉，只读台词更自然
        let spoken = reply.content
            .replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = spoken.isEmpty ? reply.content : spoken
        speaking = true
        ChatTTS.shared.speak(text) { [self] in
            // 朗读结束（播完/被打断）回调在主线程，复位按钮
            DispatchQueue.main.async { self.speaking = false }
        }
    }

    // MARK: - 表情包面板（最小可用：静态占位说明，上传未实现不做可点按钮）

    @ViewBuilder
    private var stickerSheet: some View {
        ZStack {
            GlassBackdrop()
            VStack(spacing: 14) {
                HStack {
                    Text("我的表情包")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                    Spacer()
                    Button("完成") { showStickerSheet = false }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AE.accent)
                }
                .padding(.horizontal, 20).padding(.top, 16)

                Spacer()
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                AE.textSecondary.opacity(0.4),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                            .frame(width: 96, height: 96)
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(AE.textSecondary.opacity(0.7))
                    }
                    Text("点「＋」上传 PNG 或 GIF")
                        .font(.system(size: 12.5))
                        .foregroundStyle(AE.textSecondary)
                    Text("（表情包上传功能即将上线）")
                        .font(.system(size: 11))
                        .foregroundStyle(AE.textSecondary.opacity(0.7))
                }
                Spacer()
            }
        }
        .presentationDetents([.medium])
        .glassSheetBackground()
    }

    @ViewBuilder
    private func row(_ m: Msg) -> some View {
        let mine = m.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if !mine && avatarMode != 2 {
                // 对方头像：空串/相对路径统一走 personaAvatarURL（空 → 占位）
                avatar(personaAvatarURL, name: persona.name)
            }
            if mine { Spacer(minLength: 40) }

            Text(annotated(m.content))
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.45)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(mine ? AE.accent.opacity(0.20) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AE.bubbleRadius, style: .continuous))

            if !mine { Spacer(minLength: 40) }
            if mine && avatarMode == 0 {
                // 「我」的头像从当前登录用户取（Session.avatar），空则用矢量感占位
                avatar(myAvatarURL, name: "我")
            }
        }
        .padding(.horizontal, 12)
    }

    /// 括号内容变浅：`（…）` / `(…)` 用 60% 前景色（跟安卓同一套）。
    private func annotated(_ text: String) -> AttributedString {
        var out = AttributedString()
        var depth = 0
        for ch in text {
            if ch == "（" || ch == "(" { depth += 1 }
            var piece = AttributedString(String(ch))
            if depth > 0 && annotDim {
                piece.foregroundColor = .secondary.opacity(0.6)
            }
            if ch == "）" || ch == ")" { depth = max(0, depth - 1) }
            out.append(piece)
        }
        return out
    }

    // MARK: - 错误条动作

    private var errorIcon: String {
        switch errorKind {
        case .relogin: return "person.crop.circle.badge.exclamationmark"
        case .recharge: return "creditcard.trianglebadge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch errorKind {
        case .relogin:
            Button("重新登录") { session.signOut() }
                .font(.caption).buttonStyle(.borderedProminent)
        case .recharge:
            // 去充值引导：额度不足时给重发不解决问题，主按钮仍是「重发」让用户补足后重试。
            // 商城入口在主页（MainTabView 全屏），此处不跨模块跳转，避免与其它 worker 冲突。
            Button("重发") { Task { await resend() } }
                .font(.caption).buttonStyle(.borderedProminent)
                .disabled(sending)
        case .retry, .none:
            Button("重发") { Task { await resend() } }
                .font(.caption).buttonStyle(.bordered)
                .disabled(sending)
        }
    }

    @ViewBuilder
    private func avatar(_ url: URL?, name: String) -> some View {
        // 有 URL 才走 AsyncImage；空 URL 直接出占位（AsyncImage(url:nil) 永不回调成功，
        // 会一直停在 placeholder，这里显式分流，占位也做成矢量感渐变圆底 + 首字）。
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .empty:
                    avatarPlaceholder(name)
                        .overlay(ProgressView().scaleEffect(0.5))
                default:               // .failure / @unknown
                    avatarPlaceholder(name)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
        } else {
            avatarPlaceholder(name)
        }
    }

    /// 矢量感头像占位：深墨靛蓝渐变圆底 + 首字，和 ChatListView 的占位同一套视觉。
    @ViewBuilder
    private func avatarPlaceholder(_ name: String) -> some View {
        ZStack {
            Circle().fill(
                LinearGradient(
                    colors: [AE.accentLift, AE.accentDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            Text(String(name.prefix(1)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
        .shadow(color: AE.shadowColor, radius: 2, y: 1)
    }

    /// 对方头像 URL：空 → nil（走占位）；相对路径拼当前线路 base；拼完非法也回落 nil。
    private var personaAvatarURL: URL? {
        let s = persona.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        // 相对路径（/xxx 或 xxx）：拼当前线路 base
        let joined = s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s
        return URL(string: joined)
    }

    /// 「我」的头像 URL：Session.avatar（登录/冷启动时从 /v1/me 取），空 → nil 占位。
    private var myAvatarURL: URL? {
        let s = session.avatar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        let joined = s.hasPrefix("/") ? APIClient.base + s : APIClient.base + "/" + s
        return URL(string: joined)
    }

    private func abs(_ path: String) -> String {
        if path.isEmpty { return "" }
        if path.hasPrefix("http") { return path }
        if path.hasPrefix("/") { return APIClient.base + path }
        return APIClient.base + "/" + path
    }

    /// 输入框发送。
    /// ⚠️ 旧版这里 `guard session.token != nil else { return }` 静默返回，用户看到
    /// "点发送没反应"。现在：token 缺失 → 明确提示「登录已过期」+ 重新登录入口。
    @MainActor
    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard session.token != nil else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        input = ""
        await performSend(text: text, allowLineRetry: true)
    }

    /// 失败后重发：删掉最后一条 user 及其后的回复，把那条 user 的原文重新送一遍。
    @MainActor
    private func resend() async {
        guard session.token != nil else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        guard let lastUser = msgs.last(where: { $0.role == "user" }) else { return }
        let text = lastUser.content
        if let idx = msgs.lastIndex(where: { $0.role == "user" }) {
            msgs = Array(msgs.prefix(upTo: idx))
        }
        LocalStore.save(pid: persona.id, msgs: msgs)
        await performSend(text: text, allowLineRetry: true)
    }

    /// 发送一段文本：落盘用户消息 → SSE 逐字收增量 → 落盘完整回复。
    /// 线路回落（直连→北京→备用→香港）已内置在 `APIClient.sendChatStream` 里，
    /// 这里不再做二次换线重试（否则已出字时会重复内容）。`allowLineRetry` 仅为兼容旧调用保留。
    @MainActor
    private func performSend(text: String, allowLineRetry: Bool = true) async {
        guard let token = session.token else {
            errorKind = .relogin
            withAnimation { error = "登录已过期，请重新登录后再发送。" }
            return
        }
        var mine = Msg(role: "user", content: text)
        mine.id = UUID()
        msgs.append(mine)
        LocalStore.save(pid: persona.id, msgs: msgs)

        #if DEBUG
        if demo {
            // 截图模式：假的延时回一句，保持非流式（CI 截图靠它）
            sending = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            msgs.append(Msg(role: "assistant", content: "（她笑了笑）我在听。"))
            LocalStore.save(pid: persona.id, msgs: msgs)
            sending = false
            return
        }
        #endif

        // 先插一条空 assistant，后续每个 delta 按 id 增量拼到它上面（不是替换）
        let assistantID = UUID()
        var placeholder = Msg(role: "assistant", content: "")
        placeholder.id = assistantID
        msgs.append(placeholder)

        sending = true
        error = ""
        errorKind = .none
        // 只带最近 20 条；dropLast 去掉刚插入的空 assistant，别把空内容发给模型
        let payload = msgs.dropLast().suffix(20).map { ["role": $0.role, "content": $0.content] }

        do {
            let full = try await streamReply(token: token, assistantID: assistantID, payload: payload)
            // 收尾：用完整文本校准（防止增量回调排队丢帧），落盘 + 触发云备份
            await MainActor.run {
                if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
                    msgs[i].content = full
                    scrollTick += 1
                }
                LocalStore.save(pid: persona.id, msgs: msgs)
                CloudBackup.shared.pushIfNeeded(token: token)
            }
        } catch {
            // 线路回落已由 APIClient.sendChatStream 内部完成（直连→北京→备用→香港）。
            // 这里不再二次换线重试 —— 否则已吐字的情况下会重复拼内容。
            // 只需：把最终失败归类成可见错误 + 处理空气泡（可点「重发」）。
            await reportFailure(error, assistantID: assistantID)
        }
        sending = false
    }

    /// 发一轮 SSE 流式请求（抽出来供「首次 + 线路重试」两处复用）。
    /// model 用**该角色**选中的模型（modelForPersona）；temperature 用该角色温度设置。
    private func streamReply(
        token: String, assistantID: UUID, payload: [[String: String]]
    ) async throws -> String {
        try await APIClient.sendChatStream(
            token: token, model: modelForPersona, messages: payload,
            temperature: temperature,
            onDelta: { delta in
                // onDelta 在 URLSession 后台线程回调，切回主线程改 @State 并触发滚动
                DispatchQueue.main.async {
                    guard let i = msgs.firstIndex(where: { $0.id == assistantID }) else { return }
                    msgs[i].content += delta
                    scrollTick += 1
                }
            }
        )
    }

    /// 归类错误并撤/标记空气泡。SSE 是流式，错误里可能已经出了部分字符，保留并提示重发。
    @MainActor
    private func reportFailure(_ error: Error, assistantID: UUID) {
        let (msg, kind) = Self.classify(error)
        withAnimation {
            self.error = msg
            self.errorKind = kind
        }
        if let i = msgs.firstIndex(where: { $0.id == assistantID }) {
            if msgs[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                msgs.remove(at: i)          // 一个字都没出：撤掉空气泡，可点「重发」
            } else {
                msgs[i].content += "\n（回复中断，可点「重发」）"
                LocalStore.save(pid: persona.id, msgs: msgs)
            }
        }
    }

    /// 错误 → (人话提示, 动作类型)。覆盖：401/403 掉签、402/额度不足、SSL/网络、其它。
    static func classify(_ error: Error) -> (String, ErrorKind) {
        if let api = error as? APIError {
            switch api {
            case let .http(code, msg):
                if code == 401 || code == 403 {
                    return ("登录已过期，请重新登录。", .relogin)
                }
                if code == 402 || code == 4020 || code == 4021 || code == 4022 {
                    return ("本周额度已用完，请充值墨点或开通会员。", .recharge)
                }
                let m = msg.isEmpty ? "请求失败（\(code)）" : msg
                return (m, .retry)
            case let .decode(m):
                return ("数据解析失败：\(m)", .retry)
            }
        }
        // URLError：SSL 失败（自签证书不在 ATS 例外内 / 证书链问题）、断网、超时
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorServerCertificateUntrusted,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected:
                return ("线路证书校验失败，已尝试切换线路，请重试。", .retry)
            case NSURLErrorNotConnectedToInternet:
                return ("网络未连接，请检查网络后重试。", .retry)
            case NSURLErrorTimedOut:
                return ("连接超时，请重试。", .retry)
            default:
                return (error.localizedDescription, .retry)
            }
        }
        return (error.localizedDescription, .retry)
    }

    /// 是否「线路级」错误（值得换一条线路重试）：SSL 失败 / 连不上 / 超时 / 5xx。
    static func isLineLevelError(_ error: Error) -> Bool {
        if let api = error as? APIError, case let .http(code, _) = api {
            return code == 0 || (500...599).contains(code)
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorServerCertificateUntrusted,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost:
            return true
        default:
            return false
        }
    }
}

/// 本地朗读（AVSpeechSynthesizer，iOS 7+，无需网络/权限）。
/// 单例：全局只有一个合成器，避免多次朗读叠音。
final class ChatTTS: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ChatTTS()
    private let synth = AVSpeechSynthesizer()
    /// 播完/取消的回调（主线程）。
    private var onFinish: (() -> Void)?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// 朗读一段文本；开始前先停掉上一段。`onFinish` 在结束（含被打断）时回调。
    func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        stopInternal(notify: false)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onFinish?(); return }
        self.onFinish = onFinish
        // 中文语音：优先 zh-CN，取系统默认中文嗓音（没有就用默认嗓音）
        let u = AVSpeechUtterance(string: trimmed)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(u)
    }

    /// 主动停止（按钮再点一下）。
    func stop() {
        stopInternal(notify: true)
    }

    private func stopInternal(notify: Bool) {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if notify {
            let cb = onFinish
            onFinish = nil
            DispatchQueue.main.async { cb?() }
        } else {
            onFinish = nil
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let cb = onFinish
        onFinish = nil
        DispatchQueue.main.async { cb?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cb = onFinish
        onFinish = nil
        DispatchQueue.main.async { cb?() }
    }
}
