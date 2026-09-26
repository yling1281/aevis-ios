import Foundation
import NetworkExtension
import UIKit

/// 探针的全部逻辑。
///
/// ⚠️ 整个类是 `@MainActor` 的 —— 今天刚在音乐那个 bug 上栽过一次：
/// `await` 一个 nonisolated 的 async 函数**会跳回后台线程**，
/// 于是 `@Published` 在后台被改，iOS 26 上直接崩。
/// 这里从一开始就钉在主 actor 上，别省这几个字。
@MainActor
final class ProbeModel: ObservableObject {

    /// ⚠️ 单例 + `private init()` —— 这是**故意**的写法，不是随手抄的。
    ///
    /// `@StateObject private var model = ProbeModel()` 看着更直白，
    /// 但那个默认值表达式是在 **App 的 init**（非主 actor 上下文）里求值的，
    /// 而 `ProbeModel()` 是主 actor 隔离的初始化器 —— **在今天这套
    /// `SWIFT_STRICT_CONCURRENCY=minimal` 下，那属于硬错误而不是警告**
    /// （今天已经因为它炸过一轮 14 个错）。
    ///
    /// 而「`static let shared` + 在 App 里读 `shared`」这套**是验证过能编过的** ——
    /// 管理端那个 App（`AdminStore.shared`）就是这么用的，已经出过包。
    /// **有先例的写法优先，别在这里发挥。**
    static let shared = ProbeModel()

    private init() {}

    enum Phase: Equatable {
        case idle        // 还没试
        case starting    // 正在起
        case running     // 起来了 ✅
        case failed      // 没起来 ❌

        var title: String {
            switch self {
            case .idle: return "还没测"
            case .starting: return "正在启动…"
            case .running: return "✅ 隧道起来了"
            case .failed: return "❌ 没起来"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [String] = []
    @Published private(set) var justCopied = false

    /// 扩展的 bundle id —— 必须和 `project.yml` 里那个**一字不差**。
    /// 写错的症状是"存配置时说不认识这个扩展"，很容易被误当成权限问题。
    private let tunnelBundleID = "com.aevis.vpnprobe.tunnel"

    private var manager: NETunnelProviderManager?
    private var watcher: NSObjectProtocol?
    private var deadline: Task<Void, Never>?

    // MARK: - 体检报告（界面出来之后立刻打一份）

    /// 这几行往往比后面那个报错更有用 —— 报错只说"失败了"，
    /// 这里说的是"为什么"。
    func report() {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"

        say("=== 体检 ===")
        say("App        : \(short) (\(build))")
        say("Bundle ID  : \(Bundle.main.bundleIdentifier ?? "—")")
        say("系统       : iOS \(UIDevice.current.systemVersion) · \(machineName())")
        say(contentsOf: profileReport())
        say(contentsOf: pluginReport())
        say("")
        say("这个测试「不接管任何流量」，不影响你正常上网。")
        say("")
    }

    private func machineName() -> String {
        // `UIDevice.current.model` 只会给个 "iPhone"，机型要靠 sysctl
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "iPhone" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    /// ⭐ 最关键的一项：**签名里到底带没带「网络扩展」权限。**
    ///
    /// 做法很土但很稳：描述文件（`embedded.mobileprovision`）里那段 XML
    /// 是**明文夹在二进制中间**的，直接当字符串扫就行。
    /// 正经解析要过 CMS（Security 那套在 iOS 上不一定编得过），
    /// 这里是"只回答一个问题"，不值得冒编译不过的风险。
    private func profileReport() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return [
                "签名描述文件 : 包里没有 embedded.mobileprovision",
                "  · 这一项查不了 —— 但不代表没权限，「下面那次实跑」才算数",
            ]
        }
        let text = String(decoding: data, as: UTF8.self)
        let hasNE = text.contains("com.apple.developer.networking.networkextension")

        var out = ["签名描述文件 : \(data.count) 字节"]
        out.append("  · 网络扩展权限 : " + (hasNE
            ? "✅ 在（com.apple.developer.networking.networkextension）"
            : "❌ 不在 —— 那隧道基本起不来，这条路的结论就是「这套签名不支持」"))
        out.append("  · 应用组       : " + (text.contains("application-groups") ? "在" : "不在"))
        if let exp = scan("ExpirationDate", in: text) { out.append("  · 过期时间     : \(exp)") }
        if let team = scan("TeamIdentifier", in: text) { out.append("  · 团队         : \(team)") }
        return out
    }

    /// 在明文里找 `<key>名字</key>` 后面第一对 `<string>…</string>`。
    private func scan(_ key: String, in text: String) -> String? {
        guard let k = text.range(of: "<key>\(key)</key>") else { return nil }
        let rest = text[k.upperBound...]
        guard let s = rest.range(of: "<string>"),
              let e = rest.range(of: "</string>"),
              s.upperBound <= e.lowerBound else { return nil }
        let value = String(rest[s.upperBound..<e.lowerBound])
        return value.count > 58 ? String(value.prefix(58)) + "…" : value
    }

    /// 扩展到底有没有被打进包里。
    /// ⚠️ 这一条能排掉一整类误判：**扩展没进包**和**权限不对**，
    /// 在界面上表现出来的失败几乎一样。
    private func pluginReport() -> [String] {
        guard let dir = Bundle.main.builtInPlugInsURL else {
            return ["扩展         : ❌ 包里没有 PlugIns 目录 —— 扩展没被打进去"]
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ["扩展         : " + (names.isEmpty ? "❌ PlugIns 是空的" : names.joined(separator: ", "))]
    }

    // MARK: - 真跑一次

    func start() async {
        guard phase != .starting else { return }
        phase = .starting
        justCopied = false
        say("")
        say("=== 启动隧道 ===")

        do {
            let manager = try await readyManager()
            self.manager = manager
            say("配置已存好（saveToPreferences 没报错）")

            try manager.connection.startVPNTunnel()
            say("已请求启动，等系统回话…")
            watch(manager)

            // 20 秒还没连上就认定卡住 —— 不然界面会一直转圈，看着像死了
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.phase == .starting else { return }
                self.phase = .failed
                let now = self.manager?.connection.status ?? .invalid
                self.say("❌ 20 秒了状态还是「\(self.statusText(now))」—— 隧道没能起来")
                self.say("   这种卡住最常见的两个原因：① 签名里没有网络扩展权限 ② 扩展本身没签上")
            }
        } catch {
            phase = .failed
            say("❌ 失败：\(describe(error))")
        }
    }

    func stop() {
        deadline?.cancel()
        manager?.connection.stopVPNTunnel()
        phase = .idle
        say("已请求停止")
    }

    /// 把系统里那条配置删掉（免得留一个"VPN"在设置里看着奇怪）。
    func forget() async {
        deadline?.cancel()
        manager?.connection.stopVPNTunnel()
        do {
            if let manager { try await manager.removeFromPreferences() }
            manager = nil
            phase = .idle
            say("配置已从系统里删掉")
        } catch {
            say("删除失败：\(describe(error))")
        }
    }

    private func readyManager() async throws -> NETunnelProviderManager {
        // 系统里可能已经有上一次留的，先用它，别堆一堆重复配置
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if let mine = all.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == tunnelBundleID
        }) {
            mine.isEnabled = true
            return mine
        }

        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "Aevis 探针"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Aevis VPN 探针"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    /// ⚠️ 观察回调**不是**主 actor 隔离的（哪怕 `queue: .main`，编译器也不认）——
    /// 所以里面必须 `Task { @MainActor in … }` 再动 `@Published`。
    /// 这个坑今天刚踩过（音乐闪退就是"后台改 @Published"）。
    private func watch(_ manager: NETunnelProviderManager) {
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
        watcher = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let manager = self.manager else { return }
                let status = manager.connection.status
                self.say("状态：\(self.statusText(status))")
                switch status {
                case .connected:
                    self.deadline?.cancel()
                    self.phase = .running
                    self.say("✅ 隧道起来了 —— 这套签名能跑网络扩展")
                    self.say("   也就是说，「拦抖音域名」那条路是通的，我可以接着做真功能。")
                case .disconnected:
                    if self.phase == .starting {
                        self.deadline?.cancel()
                        self.phase = .failed
                        self.say("❌ 还没到 connected 就断开了 —— 基本可以认定这条路走不通")
                    }
                default:
                    break
                }
            }
        }
    }

    private func statusText(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "无效（还没配置）"
        case .disconnected: return "已断开"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .reasserting: return "重新建立中"
        case .disconnecting: return "正在断开"
        @unknown default: return "未知(\(status.rawValue))"
        }
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)｜\(ns.localizedDescription)"
    }

    // MARK: - 日志与复制

    func say(_ line: String) { lines.append(line) }
    func say(contentsOf more: [String]) { lines.append(contentsOf: more) }

    /// 整份报告 —— 复制给客服/贴给我看的就是这个。
    func fullReport() -> String {
        (["【Aevis VPN 探针】", "结论：\(phase.title)", ""] + lines).joined(separator: "\n")
    }

    func copyAll() {
        UIPasteboard.general.string = fullReport()
        justCopied = true
    }
}
