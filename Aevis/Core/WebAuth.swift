import AuthenticationServices
import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// 系统自带的「应用内浏览器登录」。
///
/// ## 为什么用它，而不是自己画一个网页视图
/// 1. 界面上是**系统浏览器**：地址栏和域名用户看得见，他确认得了这是官方页面；
/// 2. 输验证码 / 登录百度都发生在系统浏览器里，**凭据不经过我们的代码**；
/// 3. 结束自动关窗回 App，**用户不用复制粘贴任何东西**。
///    这正是用户要的那句：「不要去发那个授权的，弄一个浏览器，登录完之后直接跳转就 OK 了」。
///
/// ## 两条必须守住的
/// - **会话要被持有**：`ASWebAuthenticationSession` 一被回收，回调永远不来，
///   表现就是"点了没反应"。所以存在属性上。
/// - **continuation 只能 resume 一次**：启动失败和回调是两条路，
///   都走到就崩。所以用一个 `finished` 标记兜住。
@MainActor
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = WebAuth()

    private var session: ASWebAuthenticationSession?

    private override init() {}

    /// 打开 `url`，等它跳到 `scheme://...`。用户取消、或启动失败 → nil。
    func run(url: URL, scheme: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            var finished = false

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, _ in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: callback)
            }
            session.presentationContextProvider = self
            // false = 复用系统浏览器的 cookie。用户如果刚在浏览器里登过，就不用再登一次。
            session.prefersEphemeralWebBrowserSession = false

            self.session = session
            if !session.start(), !finished {
                finished = true
                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        }
        if let window = scenes.first?.windows.first { return window }
        #endif
        return ASPresentationAnchor()
    }
}
