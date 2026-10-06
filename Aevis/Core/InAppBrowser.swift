import SwiftUI
import UIKit
import WebKit

/// ta 的内置浏览器：真 WebKit 内核、能真上网、登录态长期保留。
///
/// 为什么单独抽出来：原来全项目唯一用到 WebKit 的地方是「网易云登录」，
/// 那个把 WKWebView 写死绑在它自己的单例上，别人用不了。这里做成通用的，
/// 谁想开一个网页都能直接用，而且共用一份持久化的网站数据（登录一次就记住）。
///
/// 一条硬规矩：UA 必须是手机版 Safari。百度、推特这类站点会按 UA 决定
/// 给不给服务，带上本 App 的名字、或者裸露的 WKWebView 默认 UA，都会被当爬虫挡掉。
/// 这里的 UA 字符串跟仓库里「读网页」那份保持一致（那边是 private 拿不到，
/// 所以照抄同样的常量值）。

// MARK: - 引擎

/// 浏览器的引擎层。持有一个 WKWebView，负责把它自己的状态同步成可观察的。
///
/// 对外只暴露界面需要的那几样：标题、当前地址、是否在加载、进度、能不能前进后退，
/// 以及几个动作方法。界面只管订阅，不直接碰 WKWebView。
final class WebEngine: NSObject, ObservableObject {

    /// 网页标题。拿不到时是空串。
    @Published var title: String = ""
    /// 当前地址。网页里跳来跳去时跟着变。
    @Published var currentURL: URL?
    /// 是否正在加载。
    @Published var isLoading: Bool = false
    /// 加载进度，0 到 1。
    @Published var progress: Double = 0
    /// 能不能回退。
    @Published var canGoBack: Bool = false
    /// 能不能前进。
    @Published var canGoForward: Bool = false

    /// 真正的内核。界面用一层 UIViewRepresentable 把它贴到屏幕上。
    let webView: WKWebView

    /// KVO 的订阅句柄。必须留着，否则订阅立刻失效。
    private var observations: [NSKeyValueObservation] = []

    /// 手机版 Safari 的 UA。跟仓库里「读网页」那份常量值一致。
    private static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    override init() {
        let configuration = WKWebViewConfiguration()

        // 持久存储：登录一次长期有效。这是「真浏览器」和「画出来的壳」的分界。
        configuration.websiteDataStore = .default()
        // 网页要能跑脚本，不然很多站是白板。
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 内联播放：视频就在页面里播，不弹全屏。
        configuration.allowsInlineMediaPlayback = true
        // 空数组：视频不需要用户先点一下才播。
        configuration.mediaTypesRequiringUserActionForPlayback = []

        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        // 边缘滑动回退/前进，跟 Safari 手感一致（这个设在 webView 上）。
        webView.allowsBackForwardNavigationGestures = true
        // 不把本 App 暴露给站点。
        webView.customUserAgent = Self.mobileSafariUserAgent

        startObserving()
    }

    /// 把 WKWebView 的那几个属性接成可观察的。回调线程不定，统一回主线程再写。
    private func startObserving() {
        let progressToken = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.progress = view.estimatedProgress }
        }
        let titleToken = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.title = view.title ?? "" }
        }
        let urlToken = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.currentURL = view.url }
        }
        let backToken = webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoBack = view.canGoBack }
        }
        let forwardToken = webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { self?.canGoForward = view.canGoForward }
        }
        observations = [progressToken, titleToken, urlToken, backToken, forwardToken]
    }

    // MARK: 动作

    /// 打开一个地址。
    func load(_ url: URL) {
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    /// 回退一页。
    func goBack() {
        webView.goBack()
    }

    /// 前进一页。
    func goForward() {
        webView.goForward()
    }

    /// 重新加载当前页。
    func reload() {
        webView.reload()
    }

    /// 停止加载。
    func stopLoading() {
        webView.stopLoading()
    }
}

// MARK: - 导航策略

extension WebEngine: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        syncNavigationFlags()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationFlags()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        syncNavigationFlags()
    }

    /// 决定这次跳转放不放行。
    ///
    /// 规矩：http(s) 和 about/data/blob 自己处理；其它 scheme（tel、mailto、
    /// weixin、mqq、alipays、bdnetdisk 之类）一律取消、交给系统去开。
    ///
    /// 关键点有两个：
    /// 一是用 `url.scheme` 判断，不要先 `canOpenURL` 再决定放不放行 ——
    ///   `canOpenURL` 需要 Info.plist 白名单，不是所有 scheme 都在里面，
    ///   那样会把本来能开的链接也堵死；
    /// 二是每个分支都必须调用 `decisionHandler`，漏一条这次跳转就挂死。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        switch scheme {
        case "http", "https", "about", "data", "blob":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func syncNavigationFlags() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

// MARK: - 新窗口

extension WebEngine: WKUIDelegate {

    /// 网页里 `target=_blank` 的链接：不弹新窗口，就在当前这个 webView 里加载，
    /// 然后返回 nil。不然那种链接点了没反应。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - 地址规范化

/// 把用户在地址栏里敲的东西变成一个能打开的地址。
///
/// 规矩：已经带 http/https 的原样用；含空格、或者压根没有点号的，当成搜索词
/// 拼到 Bing 上（用 Bing，不用 Google，国内网络）；剩下的补个 https 前缀。
private enum BrowserAddress {

    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.contains(" ") || !trimmed.contains(".") {
            return searchURL(for: trimmed)
        }
        return URL(string: "https://" + trimmed)
    }

    /// 搜索词用 URLComponents 拼，中文会被正确编码。
    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

// MARK: - 网站数据

/// 网站数据（cookie / 缓存 / 本地存储）。
///
/// 这些数据是持久化的，所以「清除网站数据」= 退出所有网页的登录。
/// 设置页里需要时直接调。
enum InAppBrowserStore {

    /// 清掉全部网站数据。清完在主线程回调。
    static func clearAll(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        // 从「很久以前」起全算，等于全清。
        let distantPast = Date(timeIntervalSince1970: 0)
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: distantPast) {
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
}

// MARK: - 把内核贴到屏幕

/// 把引擎里的那个 WKWebView 贴满可用空间。
private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // WebView 由 WebEngine 自己持有，这里只是让它上屏幕。
    }
}

/// 「分享」用：把系统分享面板包一层。
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // 一次性面板，不需要更新。
    }
}

// MARK: - 界面

/// 通用内置浏览器。整页就是一个能真正上网的浏览器：
/// 顶部工具栏（后退 / 前进 / 刷新 / 地址栏 / 分享 / 清除），
/// 底下一条 2pt 进度条，再往下是网页本体。
struct InAppBrowserView: View {

    /// 起始地址。为 nil 时显示一个空白起始页。
    private let start: URL?
    /// 标题。非空就用它，否则用网页自己的标题。
    private let titleOverride: String

    @StateObject private var engine = WebEngine()
    @State private var addressText: String = ""
    @State private var started: Bool = false
    @State private var showShare: Bool = false
    @State private var showClearConfirm: Bool = false

    init(start: URL?, title: String = "") {
        self.start = start
        self.titleOverride = title
    }

    // MARK: 视图

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            progressBar
            Divider()
            content
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { prepareIfNeeded() }
        .onChange(of: engine.currentURL) { _, newValue in
            if let url = newValue {
                addressText = url.absoluteString
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .alert("清除网站数据", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) {
                InAppBrowserStore.clearAll {
                    engine.reload()
                }
            }
        } message: {
            Text("会清掉全部网站数据，所有网页的登录状态都会退出。")
        }
    }

    /// 显示用的标题：优先用外面给的名字，其次用网页标题，最后兜底。
    private var pageTitle: String {
        if !titleOverride.isEmpty {
            return titleOverride
        }
        if !engine.title.isEmpty {
            return engine.title
        }
        return "浏览器"
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            navButton(systemName: "chevron.left", enabled: engine.canGoBack) {
                engine.goBack()
            }
            navButton(systemName: "chevron.right", enabled: engine.canGoForward) {
                engine.goForward()
            }
            reloadButton
            addressField
            navButton(systemName: "square.and.arrow.up") {
                showShare = true
            }
            navButton(systemName: "trash") {
                showClearConfirm = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .aevisGlass(cornerRadius: 16)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func navButton(
        systemName: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.aevis(17, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var reloadButton: some View {
        Button(action: {
            if engine.isLoading {
                engine.stopLoading()
            } else {
                engine.reload()
            }
        }) {
            Image(systemName: engine.isLoading ? "xmark" : "arrow.clockwise")
                .font(.aevis(16, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.aevis(13))
                .foregroundStyle(.secondary)
            TextField("搜索或输入网址", text: $addressText)
                .font(.aevis(14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
                .submitLabel(.go)
                .lineLimit(1)
                .onSubmit { submitAddress() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .allowsHitTesting(false)
        )
    }

    // MARK: 进度条

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.clear
                Rectangle()
                    .fill(AppSettings.shared.accentColor)
                    .frame(width: proxy.size.width * CGFloat(clampedProgress))
            }
        }
        .frame(height: 2)
        .opacity(engine.isLoading ? 1 : 0)
        .animation(.linear(duration: 0.18), value: engine.progress)
        .allowsHitTesting(false)
    }

    private var clampedProgress: Double {
        guard engine.progress.isFinite else { return 0 }
        return min(max(engine.progress, 0), 1)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if started {
            BrowserWebView(webView: engine.webView)
        } else {
            startPage
        }
    }

    private var startPage: some View {
        VStack(spacing: 18) {
            Image(systemName: "safari")
                .font(.aevis(44))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text("输入网址，或者直接搜索")
                .font(.aevis(15))
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                shortcutButton("百度", address: "https://www.baidu.com")
                shortcutButton("必应", address: "https://www.bing.com")
                shortcutButton("百度网盘", address: "https://pan.baidu.com")
            }
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
        .background(Color(UIColor.systemBackground))
    }

    private func shortcutButton(_ name: String, address: String) -> some View {
        Button {
            if let target = URL(string: address) {
                open(target)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.aevis(14))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.aevis(15))
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .aevisGlass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: 行为

    /// 首次出现时决定去哪个地址。只做一次。
    private func prepareIfNeeded() {
        guard !started else { return }
        if let startURL = start {
            open(startURL)
        }
    }

    /// 打开一个地址，并把界面切到网页。地址栏同步成这个地址。
    private func open(_ url: URL) {
        started = true
        addressText = url.absoluteString
        engine.load(url)
    }

    /// 地址栏回车：把输入规范化成地址再打开。
    private func submitAddress() {
        guard let url = BrowserAddress.url(from: addressText) else { return }
        open(url)
    }

    /// 分享的内容：有当前地址就分享地址，否则分享标题。
    private var shareItems: [Any] {
        if let url = engine.currentURL {
            return [url]
        }
        return [pageTitle]
    }
}
