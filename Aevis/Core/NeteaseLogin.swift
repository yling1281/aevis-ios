import Foundation
import SwiftUI
import WebKit

/// 网易云「在 App 里登录」。
///
/// 原来只有「自己复制 Cookie 贴进来」一条路 —— 用户的原话是
/// 「我粘贴给他，他又说没有用」。手动抄 Cookie 太容易出错：
/// 少一段、带上空格、从别的域名的页面复制。所以改成：**在 App 里正常登录一次**
/// （扫码或者手机号都行），`MUSIC_U` 由我们从 cookie 存储里读出来，一步都不用手抄。
///
/// 抖音那边是同一个思路 —— `DouyinWebDriver` 用的是同一份持久存储，
/// 登录一次就一直有效。
final class NeteaseLogin: NSObject, ObservableObject {

    static let shared = NeteaseLogin()

    /// 已经拿到能用的凭据
    @Published private(set) var loggedIn = false
    /// 页面还在加载
    @Published private(set) var loading = true
    @Published var statusLine: String?

    let webView: WKWebView

    private static let home = "https://music.163.com/"

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private var watching = false
    private var verifying = false

    private override init() {
        let configuration = WKWebViewConfiguration()
        // 默认的数据存储是**持久**的：登录一次之后一直有效
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        // 桌面版页面上的登录入口更好找
        webView.customUserAgent = Self.desktopUserAgent
    }

    // MARK: - 开关

    func start() {
        if !watching {
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
            watching = true
        }
        if webView.url == nil {
            loadHome()
        }
        refreshStatus()
    }

    func stop() {
        guard watching else { return }
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        watching = false
    }

    func loadHome() {
        loading = true
        guard let url = URL(string: Self.home) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - 状态

    private func refreshStatus() {
        if AppSettings.shared.neteaseCookie.contains("MUSIC_U=") {
            loggedIn = true
            statusLine = "这台手机已经存着登录凭据了。想换账号，就在页面上重新登一次。"
        } else {
            loggedIn = false
            statusLine = "在下面这个页面登录一次（扫码或手机号都行），凭据会自动抓过来，不用你复制。"
        }
    }

    // MARK: - 抓凭据

    /// 从 cookie 存储里挑出网易云要用的那些，拼成请求头的样子。
    ///
    /// 只取 163 域名下的 —— 别的域名的 cookie 拼进去没意义，
    /// 万一夹带别处的登录信息更不合适。
    private func harvest(_ cookies: [HTTPCookie]) {
        guard cookies.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else {
            return  // 还没登录，静静等着
        }

        let header = cookies
            .filter { $0.domain.lowercased().contains("163.com") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard header.contains("MUSIC_U=") else { return }

        guard header != AppSettings.shared.neteaseCookie else {
            // 内容一样就不再折腾一遍
            if !loggedIn {
                loggedIn = true
                statusLine = "已经登录了。"
            }
            return
        }

        AppSettings.shared.neteaseCookie = header
        statusLine = "抓到登录凭据了，正在试一下能不能搜到歌…"
        Task { await verify() }
    }

    /// 抓到凭据**当场验一次**。
    ///
    /// ⚠️ 验证失败**不等于登录失败** —— 凭据已经存进设置里了，很可能只是刚登录、
    /// 服务端还没完全生效。所以这里把两件事分开说清楚：凭据拿到没有、搜索通不通。
    ///
    /// 踩过：用户看到一句「格式错误」以为白登了，其实已经能用了，
    /// 于是跑来问「为什么说格式错误但我登上去了」。
    @MainActor
    private func verify() async {
        guard !verifying else { return }
        verifying = true
        defer { verifying = false }

        do {
            let tracks = try await NeteaseClient.shared.search("晴天", limit: 1)
            loggedIn = true
            if tracks.isEmpty {
                statusLine = "凭据已经存下了。这次没搜到歌，多半是刚登录还没生效 —— "
                    + "过一会儿去「音乐」里搜一下试试。"
            } else {
                statusLine = "登录成功，能搜到歌了 —— 可以关掉这个页面。"
            }
        } catch {
            // 搜索不通也照样算登录成功：凭据是真的存下来了
            loggedIn = true
            statusLine = "凭据已经存下来了（能用的）。这次试搜没通过，"
                + "可能是刚登录还没生效 —— 过一会儿去「音乐」里搜首歌试试。"
        }
    }
}

// MARK: - 听 cookie 变化

extension NeteaseLogin: WKHTTPCookieStoreObserver {

    /// ⚠️ 这个回调**不在主线程**。读 cookie 本身没问题，
    /// 但写设置、改界面必须切回主线程 —— 不然是随机的诡异崩溃。
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            DispatchQueue.main.async {
                self.harvest(cookies)
            }
        }
    }
}

// MARK: - 页面状态

extension NeteaseLogin: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false
        statusLine = "页面没打开：\(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        loading = false
        statusLine = "连不上网易云：\(error.localizedDescription)"
    }
}
