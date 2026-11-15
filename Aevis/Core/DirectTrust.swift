import CryptoKit
import Foundation
import Security

/// 直连线路的 TLS 证书固定（2026-11-15 从 `AccountService.swift` 抽出来）。
///
/// **为什么要抽**：`AccountEndpoint.swift` 是主 App 和管理端**共用**的一份，
/// 它里头的 `session(for:)` 需要「直连那条线路用带证书固定的 session」。
/// 而 `DirectTrustDelegate` 原来写在 `AccountService.swift` 里 —— 那个文件依赖
/// `AppSettings`（两千多行），管理端只要引用一下就要连坐把整个设置层搬进去，
/// 上一轮就是这么报的：
///
///     Aevis/Core/AccountEndpoint.swift:125:20: error: cannot find 'AccountService' in scope
///     Aevis/Core/AccountEndpoint.swift:124:56: error: cannot find 'DirectTrustDelegate' in scope
///
/// 抽出来之后：本文件只依赖 Foundation / Security / CryptoKit，**自包含**，
/// 主 App、管理端、以后任何端都能直接编进来，不用再拖一串。

/// 只对直连 IP 做证书固定校验，其他域名交给系统默认处理。
final class DirectTrustDelegate: NSObject, URLSessionDelegate {

    /// 直连 IP。只有它走这套校验。
    static let host = "103.236.72.107"

    /// `/opt/aevis/tls/direct.crt` 的 DER SHA256（叶子证书，不是 CA）。
    static let pinnedSHA256 = "62691735bdcc2c940672e5fda640d1f52a534f66da2a9320083ec2eb39bb7d2c"

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == Self.host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
        guard let leaf = chain?.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        if digest == Self.pinnedSHA256 {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            // 对不上就断 —— 宁可这条线路不可用，也不能把 token 发给未知服务器
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// 带证书固定的 session。
///
/// ⚠️ 必须由静态常量持有 —— `URLSession` 只**弱引用** delegate，
/// 随手 `URLSession(configuration:delegate:)` 建一个临时实例，
/// 下一个 runloop 就把 delegate 丢了，固定校验静默失效。
enum DirectTrustSession {
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg,
                          delegate: DirectTrustDelegate(),
                          delegateQueue: nil)
    }()
}
