import Foundation

/// 用户协议的同意状态 —— **本机状态，不联网、不参与备份**。
///
/// 老板 2026-10-06 的口径：「打开 app 要同意协议，不同意不准打开」。
/// 这一层只管"同意过没有"，弹不弹、拦不拦由 `RootView` / `AevisApp` 决定。
///
/// ## 版本号
/// `currentVersion` 就是"当前生效的协议版本"。**协议正文一改就要把它 +1** ——
/// 用户存的是"同意过的版本"，对不上当前版本就会被重新弹一次
///（老板要的是"协议变了要重新同意"，不是"同意一次就一劳永逸"）。
///
/// ## 为什么用 UserDefaults
/// 它天然是"本机、即时、不值一提"的状态：一个短字符串，读写在主线程，
/// 不需要落盘文件、也不该跟着网盘搬家（换台设备本来就该重新同意一次）。
final class AgreementStore: ObservableObject {
    static let shared = AgreementStore()

    /// 当前生效的协议版本。**改了协议正文就 +1。**
    static let currentVersion = "1.0"

    /// UserDefaults 的键。带 `aevis.` 前缀，避免和别的库撞名。
    private static let acceptedVersionKey = "aevis.agreement.acceptedVersion"

    /// 用户同意过的版本号。没同意过就是空串。
    ///
    /// 写入即落盘（`didSet`）—— 同意是一次性的低概率动作，
    /// 每次都写不会带来任何负担，反而省得"忘了存、重启又弹一次"。
    @Published var acceptedVersion: String = "" {
        didSet {
            UserDefaults.standard.set(acceptedVersion, forKey: Self.acceptedVersionKey)
        }
    }

    /// 同意过没有。**版本对得上才算数** —— 协议升级后这里会重新变回 false。
    var accepted: Bool {
        acceptedVersion == Self.currentVersion
    }

    private init() {
        #if DEBUG
        // ⭐ CI 的模拟器截图靠启动参数直达各个界面（见 `DemoSeed`），而协议门在
        //    **整个 App 的最外层** —— 不在这跳过的话，那 40 多张图会**全部拍到协议页**，
        //    等于整个截图自检一次全废（每次都是同一屏）。
        //
        // 判据与 `DeviceGate.swift` 里"跳过授权门禁"的那行**完全一致**
        //（`-aevisSkipGate` 或 `-aevisDemo`，后者已隐含前者），不另发明一套参数。
        //
        // 🔴 只在 Debug 构建里存在 —— 正式包（Release）里这段**压根编不进去**，
        //    用户没有任何办法绕过协议页。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-aevisSkipGate") || args.contains("-aevisDemo") {
            acceptedVersion = Self.currentVersion
            return
        }
        // 反过来那条：**强制显示协议页**，本机存过同意也照样显示。
        //
        // 为什么必须有：上面那个跳过分支会顺手把"已同意"写进 UserDefaults，
        // 于是截图清单里排在它后面的任何一条都再也看不到协议页了。
        // 跟 `-aevisShowGate`（强制显示未授权门禁页）是同一个路子。
        if args.contains("-aevisShowAgreement") {
            acceptedVersion = ""
            return
        }
        #endif

        acceptedVersion = UserDefaults.standard.string(forKey: Self.acceptedVersionKey) ?? ""
    }

    /// 用户点了「同意并继续」：记下当前版本。
    func accept() {
        acceptedVersion = Self.currentVersion
    }

    /// 清掉同意记录（目前没有 UI 入口，留给以后"撤回同意 / 重新走一遍"用）。
    func reset() {
        acceptedVersion = ""
    }
}
