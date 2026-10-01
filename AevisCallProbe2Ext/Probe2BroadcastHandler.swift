import ReplayKit

/// ## 二探针里那个**假扩展** —— 什么都不做
///
/// 它存在的唯一理由：让二探针那个包里**多一个 `.appex`**，
/// 从而复现主 App 的处境 —— 签名的时侯**要管两个可执行文件**。
///
/// ## 为什么非得这么测
///
/// 主 App（`com.aevis.ios`）里嵌着 `AevisBroadcast.appex`
/// （`com.aevis.ios.broadcast`）。侧载重签时：
///
///   · **每一个可执行文件都要单独签一份**
///   · **每个 bundle 的描述文件必须覆盖它自己的 id**
///
/// 第一颗探针（`AevisCallProbe`）只有一个可执行文件，所以它验的是
/// "一个干净的小包能不能拿到通话资格"。它俩的差别就在这里。
///
/// ## 这个类为什么是空的
///
/// **故意空的。** 它只要能编过、能被嵌进去就够了 ——
/// 里面写任何逻辑都会变成新的变量。要测的是"包的结构"，
/// 不是"扩展干了什么"。
///
/// ⚠️ 但仍要老老实实实现 `RPBroadcastSampleHandler` 那三个 required 方法：
///    不实现的话**编译能过**，但系统在装载扩展时可能直接拒掉 ——
///    那就变成了"扩展本身不合格"，而不是"嵌了扩展导致资格丢失"，结论会被带偏。
final class Probe2BroadcastHandler: RPBroadcastSampleHandler {

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 故意什么都不做。
    }

    override func broadcastPaused() {
        // 故意什么都不做。
    }

    override func broadcastResumed() {
        // 故意什么都不做。
    }

    override func broadcastFinished() {
        // 故意什么都不做。
    }
}
