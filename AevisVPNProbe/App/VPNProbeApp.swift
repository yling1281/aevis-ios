import SwiftUI

/// ## VPN 探针 —— **这不是功能，是一次体检**
///
/// 要回答的只有一句话：
///
/// > **你这套签名，能不能让 App 起一个网络扩展（VPN 隧道）？**
///
/// 「拦掉抖音域名、不用快捷指令」那条路，只有在隧道**能起来**的前提下才谈得上。
/// 隧道依赖一个**受限权限**（`com.apple.developer.networking.networkextension`）——
/// 它必须在签名用的那份描述文件里。而那份东西是签名工具（全能签之类）给的，
/// 我们既看不到、也改不了。**所以只能装上去试。**
///
/// ⚠️ 几个刻意的决定，都是为了"结论可信"：
///
/// 1. **独立成一个包，主 App 一点都不碰。**
///    万一扩展签名签不明白，**连装都装不上** —— 不能拿买家那个包去赌。
/// 2. **隧道不接管任何流量**（见 `PacketTunnelProvider`），
///    所以测试期间正常上网不受影响，他不用怕点一下网就断了。
/// 3. **报告分两条独立的路**：
///    ① 从签名描述文件里**直接找**那个权限名（静态就能看出来）
///    ② 真的去起隧道，把系统的报错原样打出来（运行时才知道）
///    两条都对上，结论才站得住。
@main
struct VPNProbeApp: App {
    // ⚠️ 用 `ProbeModel.shared`（而不是 `ProbeModel()`）—— 理由见 ProbeModel 里那段注释：
    //    主 actor 隔离的初始化器**不能**在 App 的 init 里直接调，会编译不过；
    //    而「读 singleon 的 shared」这套是管理端验证过能过的。
    @StateObject private var model = ProbeModel.shared

    var body: some Scene {
        WindowGroup {
            ProbeView().environmentObject(model)
        }
    }
}
