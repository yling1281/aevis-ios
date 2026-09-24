import Foundation
import SwiftUI
import WebKit

/// 用**网页版**做抖音的写操作：点赞、评论。
///
/// **为什么不用接口**：抖音的写接口要 `a_bogus` 签名，那是跑混淆 JS 算出来的，
/// 我们复刻不了。但**网页版自己会算** —— 所以干脆直接驱动网页：
/// 把抖音装进 App 内的 WKWebView，用 JS 去点它**真实的按钮**。
/// 签名、Cookie、风控全由它自己的前端处理，我们不掺和。
///
/// **代价必须讲清楚**（不能糊弄）：
/// - 依赖页面结构。抖音一改版，选择器就失效 ——
///   所以每次操作都**如实返回"点到了 / 没找到按钮"**，绝不假装成功。
/// - 登录要在**这个浏览器里**登一次（扫码或手机号），
///   Cookie 存在 App 自己的网站数据里，之后一直有效，和 Safari 不共享。
///
/// 这也是为什么它比"贴 Cookie 调接口"更稳：不用手抄 Cookie，
/// 也不用等签名算法被逆向出来。
final class DouyinWebDriver: NSObject, ObservableObject {
    static let shared = DouyinWebDriver()

    @Published private(set) var pageTitle = ""
    @Published private(set) var currentURL = ""
    @Published private(set) var busy = false
    /// 最近一次操作的结果，界面上直接显示。
    @Published var statusLine: String?

    let webView: WKWebView

    private static let home = "https://www.douyin.com/"

    private override init() {
        let configuration = WKWebViewConfiguration()
        // 默认的数据存储是**持久**的：登录一次之后一直有效
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // 桌面版页面结构比手机版稳一些，按钮也好找
        webView.customUserAgent = Self.desktopUserAgent
    }

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - 加载

    func loadHome() {
        guard let url = URL(string: Self.home) else { return }
        webView.load(URLRequest(url: url))
    }

    /// 打开一个具体的作品页（比如分享链接解析出来的地址）。
    func load(_ link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            statusLine = "这个链接打不开。"
            return
        }
        webView.load(URLRequest(url: url))
    }

    var isLoaded: Bool {
        !currentURL.isEmpty
    }

    // MARK: - 点赞

    /// 在当前页面上点个赞。
    ///
    /// 选择器列了多个候选 —— 抖音的 DOM 在不同版本里叫法不一样，
    /// 挨个试，试到哪个就回报哪个；一个都没有就如实说"没找到"。
    func like() async -> String {
        guard isLoaded else { return "先打开一个抖音页面再说。" }
        busy = true
        defer { busy = false }

        let script = """
        (function () {
          var candidates = [
            '[data-e2e="video-like"]',
            '[data-e2e="like-icon"]',
            '[data-e2e="feed-like"]',
            'span[data-e2e="video-like-count"]',
            '.like-icon',
            '[aria-label*="赞"]'
          ];
          for (var i = 0; i < candidates.length; i++) {
            var node = document.querySelector(candidates[i]);
            if (node) {
              var target = node.closest('[role="button"]') || node;
              target.click();
              return candidates[i];
            }
          }
          return '';
        })();
        """

        let result = await evaluate(script)
        let hit = (result as? String) ?? ""
        let message = hit.isEmpty
            ? "没找到点赞按钮 —— 可能是页面还没加载完，或者抖音改版了。"
            : "点了赞（用的是选择器 \(hit)）。"
        statusLine = message
        return message
    }

    // MARK: - 评论

    /// 在当前页面上写一条评论。
    ///
    /// 两步：先点开评论框，再往输入框里写。写进 React 的受控输入框
    /// **不能直接赋值** —— 得用原生 setter 再派发 input 事件，否则框架不认。
    func comment(_ text: String) async -> String {
        guard isLoaded else { return "先打开一个抖音页面再说。" }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return "要点评就得先写点内容。" }

        busy = true
        defer { busy = false }

        // 第一步：把评论框打开
        let openScript = """
        (function () {
          var candidates = [
            '[data-e2e="comment-icon"]',
            '[data-e2e="feed-comment-icon"]',
            '[aria-label*="评论"]'
          ];
          for (var i = 0; i < candidates.length; i++) {
            var node = document.querySelector(candidates[i]);
            if (node) { (node.closest('[role="button"]') || node).click(); return candidates[i]; }
          }
          return '';
        })();
        """
        _ = await evaluate(openScript)

        // 给评论面板一点时间弹出来
        try? await Task.sleep(nanoseconds: 900_000_000)

        // 第二步：写进去（用原生 setter，受控组件才认）
        let escaped = Self.javaScriptLiteral(body)
        let fillScript = """
        (function () {
          var box = document.querySelector('[data-e2e="comment-input"]')
                 || document.querySelector('textarea[placeholder]')
                 || document.querySelector('div[contenteditable="true"]');
          if (!box) { return 'no-input'; }

          var setter = Object.getOwnPropertyDescriptor(
            window.HTMLTextAreaElement.prototype, 'value'
          );
          if (box.tagName === 'TEXTAREA' && setter && setter.set) {
            setter.set.call(box, \(escaped));
          } else {
            box.textContent = \(escaped);
          }
          box.dispatchEvent(new Event('input', { bubbles: true }));
          box.dispatchEvent(new Event('change', { bubbles: true }));
          return 'filled';
        })();
        """

        let filled = (await evaluate(fillScript) as? String) ?? ""
        switch filled {
        case "filled":
            statusLine = "内容写进评论框了 —— 发出去这一步你自己点一下，我不替你按发送。"
            return statusLine ?? ""
        case "no-input":
            statusLine = "没找到评论输入框 —— 可能要先点开评论，或者抖音改版了。"
            return statusLine ?? ""
        default:
            statusLine = "评论没写进去（\(filled)）。"
            return statusLine ?? ""
        }
    }

    /// 点发送。
    ///
    /// **单独留一个动作给用户**：评论发出去撤不回来，
    /// 按设置里的「高危操作二次确认」，这一步要么用户自己点，要么明确按一次。
    func submitComment() async -> String {
        let script = """
        (function () {
          var candidates = [
            '[data-e2e="comment-publish"]',
            '[data-e2e="comment-submit"]',
            'button[type="submit"]'
          ];
          for (var i = 0; i < candidates.length; i++) {
            var node = document.querySelector(candidates[i]);
            if (node && !node.disabled) { node.click(); return candidates[i]; }
          }
          return '';
        })();
        """
        let hit = (await evaluate(script) as? String) ?? ""
        let message = hit.isEmpty
            ? "没找到发送按钮 —— 自己点一下更保险。"
            : "点了发送（\(hit)）。刷一下看看有没有出去。"
        statusLine = message
        return message
    }

    // MARK: - 执行 JS

    @MainActor
    private func evaluate(_ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    DispatchQueue.main.async {
                        self.statusLine = "执行出错：\(error.localizedDescription)"
                    }
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: value)
            }
        }
    }

    /// 把一段文字安全地嵌进 JS 字符串字面量里。
    /// 直接拼接会让引号、换行把脚本搞坏（评论内容里这些都有）。
    static func javaScriptLiteral(_ text: String) -> String {
        var out = "\""
        for character in text {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        out += "\""
        return out
    }

    // MARK: - 把网页的登录态交给接口那边

    /// 从网页的 cookie 里把登录凭据抓出来存进设置。
    ///
    /// 为什么要这一步：网页里登录之后，**App 内的网页自己**是登录状态，
    /// 但走接口的那些功能（比如解析分享链接拿详细信息）读的是 `AppSettings` 里的
    /// cookie，两者本来不通。抓一次，两边就都通了 —— 用户不用再手动复制。
    ///
    /// - Parameter quiet: 自动抓时不要打扰界面（否则会把用户刚点的操作结果冲掉）
    func harvestCookie(quiet: Bool = true) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }

            let header = cookies
                .filter { cookie in
                    let domain = cookie.domain.lowercased()
                    return domain.contains("douyin.com")
                        || domain.contains("snssdk")
                        || domain.contains("bytedance")
                }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            DispatchQueue.main.async {
                guard header.contains("sessionid") else {
                    if !quiet {
                        self.statusLine = header.isEmpty
                            ? "网页里还没有 cookie —— 先在页面上登录一次。"
                            : "有 cookie，但里面没有登录凭据（sessionid）。先在页面上登录。"
                    }
                    return
                }
                guard header != AppSettings.shared.douyinCookie else { return }

                AppSettings.shared.douyinCookie = header
                self.statusLine = "抖音登录凭据存下来了，接口那边也能用了。"
            }
        }
    }
}

// MARK: - 页面状态

extension DouyinWebDriver: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        currentURL = webView.url?.absoluteString ?? ""
        webView.evaluateJavaScript("document.title") { value, _ in
            DispatchQueue.main.async {
                self.pageTitle = (value as? String) ?? ""
            }
        }
        // 顺手看一眼登录了没有 —— 用户在网页里登上了，接口那边立刻就能用
        harvestCookie()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        statusLine = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        statusLine = "连不上：\(error.localizedDescription)"
    }
}
