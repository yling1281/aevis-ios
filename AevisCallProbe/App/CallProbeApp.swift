import SwiftUI

/// ## 通话探针 —— **这不是功能，是一次体检**
///
/// 要回答的只有一句话：
///
/// > **这套签名（侧载重签之后），能不能让 App 弹出系统级的通话界面？**
///
/// 详细背景见 `CallProbeModel` 顶上那段注释。一句话版本：
/// Apple 的 `LiveCommunicationKit` 里「主动拨出」这条路**不需要推送服务器**，
/// 但它要求 App 有通话资格（`aps-environment`），而那句话写在**描述文件**里 ——
/// 而描述文件是全能签给的，我们看不到也改不了。**只能装上去试。**
///
/// ⚠️ 几个刻意的决定，都是为了"结论可信"：
///
/// 1. **独立成一个包，主 App 一点都不碰。**
///    探针要声明 `aps-environment`、要加 `voip` 后台模式、要动 entitlements ——
///    这些在**买家那个包**上做是有风险的（描述文件对不上连装都装不上）。
///    所以它自己一个包（`com.aevis.callprobe`），赌输了也不影响别人。
/// 2. **不接真实通话**（3 秒自动挂断）：只回答"界面弹不弹"，
///    不做媒体流，变量越少结论越可信。
/// 3. **报告分两条独立的路**：
///    ① 从签名描述文件里**直接找** `aps-environment`（静态就能看出来）
///    ② 真的去拨一次，把系统的原始报错打出来（运行时才知道）
///    两条都对上，结论才站得住。
@main
struct CallProbeApp: App {
    // ⚠️ 用 `CallProbeModel.shared`（而不是 `CallProbeModel()`）—— 理由见
    //    CallProbeModel 里那段注释：主 actor 隔离的初始化器**不能**在 App 的
    //    init 里直接调，会编译不过；而「读单例的 shared」这套是验证过能过的。
    @StateObject private var model = CallProbeModel.shared

    var body: some Scene {
        WindowGroup {
            CallProbeView().environmentObject(model)
        }
    }
}
