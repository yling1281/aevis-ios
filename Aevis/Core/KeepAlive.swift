import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 切后台时，给「正在生成的那一轮」续命。
///
/// 用户 2026-11-12：「只要切后台，它就会停止对话」。
///
/// iOS 在 App 进入后台后几秒就会挂起进程，正在跑的流式请求随之断掉 ——
/// 表现就是「切出去回个消息，回来发现 ta 说到一半没了」。
///
/// 这里申请一个 background task：系统一般给 ~30 秒（有音频/定位等后台能力时更久）。
/// 够把一轮普通回复写完。超时后系统仍会挂起，那时 `ChatStore` 里已经落盘的部分
/// 照常显示，不会丢已经收到的字。
///
/// ⚠️ 这**不是**"真正的后台运行"—— 想长时间后台只能开音频/定位权限，
///    那种做法会被 App Store 判滥用。30 秒是合规范围内能给的全部。
enum KeepAlive {

    #if canImport(UIKit)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// 进后台时调一次。重复调会先结束旧的再申请新的。
    static func begin(seconds: TimeInterval = 25) {
        #if canImport(UIKit)
        end()
        task = UIApplication.shared.beginBackgroundTask(withName: "aevis.reply") {
            // 系统要收回了：立刻结束，别被强杀（强杀会留一堆脏状态）
            end()
        }
        guard task != .invalid else { return }
        // 自己再兜一层闹钟：到点主动交还，比等系统来收更干净
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            end()
        }
        #endif
    }

    /// 回前台、或这一轮已经结束时调。
    static func end() {
        #if canImport(UIKit)
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
        #endif
    }
}
