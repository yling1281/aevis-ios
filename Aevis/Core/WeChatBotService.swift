//
//  WeChatBotService.swift
//  Aevis
//
//  ⚠️ 2026-11-02 重写：**底层不再是 App 内置 Linux。**
//
//  原来这套是靠 iSH（真 Alpine）在手机里跑 `wechat_bind.sh` + curl 去连腾讯 iLink。
//  现在改成：**全部走我们自己的服务器**（4-4 上的 aevis_wxbot，背后是 HK 的
//  wx-login / OpenClaw 通道）。客户端只做三件事 ——
//
//    1. 拉状态（/v1/wxbot/status、/v1/wxbot/qr）
//    2. 点一下换码（/v1/wxbot/refresh）
//    3. 绑完记一笔（/v1/wxbot/bind、/v1/wxbot/my）
//
//  直接好处：App 不用带 200MB 的 rootfs、不用链 libaevisish.a、CI 不用每次下载解压，
//  也不会再有「内核崩了只能重启 App」这种事。
//
//  ⚠️ 对外接口**一个都没改名**（state / probes / qrPayload / incoming /
//  received / lastError / boundSummary / probe / startBind / unbind /
//  startPolling / stopPolling）—— WeChatBotCard.swift 不用改一行。
//
//  ## 线程口径（沿旧约定）
//  故意不标 `@MainActor`：调用点散在后台任务里。
//  所有 `@Published` 一律从 `setXxx` 过一道，避免 "Publishing changes from
//  background threads"，也就不会在 iOS 26 上硬崩。
//

import Foundation
import Combine

final class WeChatBotService: ObservableObject {

    static let shared = WeChatBotService()

    // MARK: - 状态

    enum State: Equatable {
        case off
        case probing
        case ready
        case waitingScan
        case bound
        case polling
        case frozen(String)
        case failed(String)

        var label: String {
            switch self {
            case .off: return "没在跑"
            case .probing: return "正在忙…"
            case .ready: return "自检跑完了"
            case .waitingScan: return "出码了，等你扫"
            case .bound: return "已绑定"
            case .polling: return "已绑定，正在收消息"
            case .frozen(let why): return "会话超时了：\(why)"
            case .failed(let why): return "出错了：\(why)"
            }
        }

        var isBound: Bool {
            switch self {
            case .bound, .polling, .frozen: return true
            case .off, .probing, .ready, .waitingScan, .failed: return false
            }
        }
    }

    /// 一项自检的真实结果。界面直接显示，不做美化。
    struct ProbeResult: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var command: String
        var output: String
        var ok: Bool
    }

    /// 来往消息。服务器版由服务端收发，客户端不再逐条解析 —— 结构留着兼容界面。
    struct Incoming: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var text: String
        var at: Date
        var peer: String? = nil
        var context: String? = nil
    }

    @Published private(set) var state: State = .off
    @Published private(set) var probes: [ProbeResult] = []
    @Published private(set) var qrPayload: String?
    @Published private(set) var incoming: [Incoming] = []
    @Published private(set) var received = 0
    @Published var lastError: String?

    // MARK: - 主线程改 @Published

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func setState(_ next: State) { onMain { self.state = next } }
    private func setProbes(_ next: [ProbeResult]) { onMain { self.probes = next } }
    private func setQR(_ next: String?) { onMain { self.qrPayload = next } }
    private func setError(_ next: String?) { onMain { self.lastError = next } }

    private init() {}

    // MARK: - 网络

    private var base: String { AevisHosts.accountBase }

    private func call(_ path: String, method: String = "GET") async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        let acc = AppSettings.shared.accountEmail
        if !acc.isEmpty { req.setValue(acc, forHTTPHeaderField: "X-Account") }
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["data"] as? [String: Any]) ?? obj
    }

    /// 后端 phase → 本地 State。
    private func map(_ d: [String: Any]) -> State {
        let phase = (d["phase"] as? String ?? "").lowercased()
        switch phase {
        case "connected", "bound", "online", "running":
            return AppSettings.shared.weChatBotEnabled ? .polling : .bound
        case "waiting", "waiting_scan", "scan", "pending", "new":
            return .waitingScan
        case "frozen", "timeout", "session_timeout":
            return .frozen(d["message"] as? String ?? "会话超时")
        case "error", "failed":
            return .failed(d["message"] as? String ?? "服务端报错")
        case "":
            return .failed("服务端没回状态")
        default:
            return .ready
        }
    }

    var isReady: Bool { AppSettings.shared.weChatBotEnabled }

    /// 一句能直接显示在界面上的绑定摘要。
    var boundSummary: String {
        let settings = AppSettings.shared
        guard settings.weChatBotBoundAt > 0 else { return "还没绑定" }
        let date = Date(timeIntervalSince1970: settings.weChatBotBoundAt)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let id = settings.weChatBotILinkID.isEmpty ? "服务器没有返回 bot id" : settings.weChatBotILinkID
        return "已绑定 · \(id) · " + f.string(from: date)
    }

    // MARK: - 自检（三项，全部打我们服务器）

    func probe() async {
        setState(.probing)
        setError(nil)
        var rows: [ProbeResult] = []

        if let st = await call("/v1/wxbot/status") {
            let phase = st["phase"] as? String ?? "?"
            let msg = st["message"] as? String ?? ""
            rows.append(ProbeResult(
                title: "服务器状态",
                command: "GET /v1/wxbot/status",
                output: "phase=\(phase) \(msg)",
                ok: phase != "error" && phase != "failed"))
            setState(map(st))
        } else {
            rows.append(ProbeResult(
                title: "服务器状态",
                command: "GET /v1/wxbot/status",
                output: "连不上（网络或服务端）",
                ok: false))
            setState(.failed("连不上服务器"))
        }

        if let qr = await call("/v1/wxbot/qr"),
           let url = qr["qr"] as? String, !url.isEmpty {
            setQR(url)
            rows.append(ProbeResult(title: "二维码", command: "GET /v1/wxbot/qr",
                                    output: url, ok: true))
        } else {
            setQR(nil)
            rows.append(ProbeResult(title: "二维码", command: "GET /v1/wxbot/qr",
                                    output: "没拿到二维码地址", ok: false))
        }

        // 绑定记录要登录态，没登录就别算失败
        if !AppSettings.shared.accountEmail.isEmpty {
            let my = await call("/v1/wxbot/my")
            let bot = my?["bot_account"] as? String ?? ""
            rows.append(ProbeResult(title: "我的绑定", command: "GET /v1/wxbot/my",
                                    output: bot.isEmpty ? "还没绑过" : bot,
                                    ok: !bot.isEmpty))
        } else {
            rows.append(ProbeResult(title: "我的绑定", command: "GET /v1/wxbot/my",
                                    output: "没登录，跳过", ok: true))
        }

        setProbes(rows)
    }

    func recheckBackground() async {
        await probe()
    }

    // MARK: - 出码 / 绑定

    /// 让服务器出一张**全新**二维码，然后开始盯状态。
    func startBind() async {
        setError(nil)
        setState(.probing)
        _ = await call("/v1/wxbot/refresh", method: "POST")
        // 服务端限流 15 秒一次：刷完等一下再读，否则读到的是上一张。
        try? await Task.sleep(nanoseconds: 900_000_000)
        await pollOnce()
        if case .waitingScan = state { startPolling() }
    }

    /// 解绑：服务器那边的会话由后台清，这里只清本地这份记录。
    func unbind() async {
        stopPolling()
        let s = AppSettings.shared
        s.weChatBotILinkID = ""
        s.weChatBotBoundAt = 0
        setQR(nil)
        setState(.off)
    }

    // MARK: - 轮询

    private var pollingTask: Task<Void, Never>?

    private func pollOnce() async {
        guard let d = await call("/v1/wxbot/qr") else {
            setError("读状态失败")
            return
        }
        if let url = d["qr"] as? String, !url.isEmpty { setQR(url) }
        setState(map(d))

        // 服务器给了 bot id 且本地没有 → 记下来，并把这笔绑定挂到自己账号上
        if let id = d["accountId"] as? String, !id.isEmpty,
           AppSettings.shared.weChatBotILinkID != id {
            AppSettings.shared.weChatBotILinkID = id
            AppSettings.shared.weChatBotBoundAt = Date().timeIntervalSince1970
            if !AppSettings.shared.accountEmail.isEmpty {
                _ = await call("/v1/wxbot/bind", method: "POST")
            }
        }
    }

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func reconnectIfNeeded() {
        if AppSettings.shared.weChatBotEnabled, AppSettings.shared.weChatBotBoundAt > 0 {
            startPolling()
        }
    }
}
