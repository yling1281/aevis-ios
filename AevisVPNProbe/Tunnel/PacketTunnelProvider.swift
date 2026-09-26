import Foundation
import NetworkExtension

/// 探针的隧道本体（跑在独立进程里）。
///
/// ## 它**故意什么都不拦**
///
/// 只圈了一个「测试网段」：`192.0.2.0/24`（RFC 5737 的文档示例段，现实中不存在），
/// 并且**显式排除默认路由**。所以隧道连上之后，你的正常上网**一点不受影响**。
///
/// 为什么这么设计：探针要回答的是"**能不能起来**"，
/// 不是"拦得准不准"。要是顺手把默认路由接管了，测试期间手机就上不了网 ——
/// 那会让一次体检变成一次事故，而且他以后不敢再点。
///
/// ⚠️ 也**故意不设 `dnsSettings`**：设了会把系统的 DNS 抢过来，
/// 同样是"体检不该做的事"。真做功能时，DNS 才是主战场（那一步在隧道能起来之后）。
final class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]? = nil,
                              completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["10.77.0.1"], subnetMasks: ["255.255.255.255"])
        // 只把那个"不存在的网段"圈进来 —— 等于什么都没圈
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "192.0.2.0",
                                           subnetMask: "255.255.255.0")]
        // 双保险：默认路由明确排除在外
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        // 这里要是报错，就是"扩展本身跑不起来"（多半是签名/权限）——
        // 系统会把它记在日志里，App 那边看到的是"连接失败/断开"。
        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
