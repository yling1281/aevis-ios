import Foundation

enum DouyinError: LocalizedError {
    case notLoggedIn
    case needsSignature
    case badLink
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "还没登录抖音。去设置 →「抖音」里把 Cookie 贴上。"
        case .needsSignature:
            return "这个操作需要抖音的请求签名（a_bogus / X-Bogus），现在还没接。"
        case .badLink:
            return "这段文字里没找到抖音链接。"
        case let .http(code):
            return "抖音返回 \(code)。可能是被风控拦了，换个网络或过一会儿再试。"
        }
    }
}

/// 解析出来的一条抖音作品。
struct DouyinShare: Equatable {
    var title: String = ""
    var author: String = ""
    var cover: String = ""
    var link: String = ""
    var videoID: String = ""

    var isEmpty: Bool {
        title.isEmpty && author.isEmpty
    }

    var summary: String {
        var lines: [String] = []
        if !author.isEmpty { lines.append("@\(author)") }
        if !title.isEmpty { lines.append(title) }
        if !videoID.isEmpty { lines.append("作品 ID：\(videoID)") }
        return lines.joined(separator: "\n")
    }
}

/// 抖音请求的签名。
///
/// **为什么单独抽出来**：抖音的接口需要 `a_bogus`（老的叫 `X-Bogus`）签名，
/// 它是由一段**混淆过的 JS** 算出来的，而且对方会改。这种东西不能凭记忆写 ——
/// 写出来的一定是错的，还会表现成"请求发出去了但一直失败"，比不做更糟。
///
/// 所以留一个接口：以后要么把那段 JS 内嵌进 WebView 跑、要么接一个自建算签服务，
/// 实现这个协议就能直接用，**上层的点赞/评论/发布一行都不用改**。
protocol DouyinSigner {
    func sign(url: String, params: [String: String], cookie: String) -> [String: String]?
}

/// 抖音。**能真做的部分做真的，做不到的部分如实说。**
///
/// 现在真的能用：
/// - 从分享文案里**抠出链接**
/// - **解析分享页**（标题、作者、封面、作品 ID）—— 走公开分享页，不需要签名
/// - 一键在 App 里打开
///
/// 还没接的：点赞 / 收藏 / 评论 / 关注 / 发布。原因是需要签名（见上）。
final class DouyinClient {
    static let shared = DouyinClient()

    /// 有实现才能用写操作。现在是 nil。
    var signer: DouyinSigner?

    private init() {}

    var cookie: String {
        AppSettings.shared.douyinCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isLoggedIn: Bool {
        cookie.contains("sessionid")
    }

    /// 写操作到底能不能用。界面和工具都问这个，不各自猜。
    var canWrite: Bool {
        isLoggedIn && signer != nil
    }

    private static let mobileAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    // MARK: - 抠链接

    /// 从一段分享文案里找出抖音链接。
    /// 分享出来的东西长这样：
    /// 「7.53 复制打开抖音，看看【xxx的作品】…… https://v.douyin.com/iXXXXX/」
    static func extractLink(from text: String) -> URL? {
        let pattern = #"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
            // 尾巴上常常粘着中文标点或右括号，切掉
            let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "，。、）)】」》\"'"))
            if let url = URL(string: cleaned),
               let host = url.host,
               host.contains("douyin.com") || host.contains("iesdouyin.com") {
                return url
            }
        }
        // 没有抖音的，但有别的链接也认 —— 用户可能就想让它打开
        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let raw = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "，。、）)】」》\"'"))
            if let url = URL(string: raw) { return url }
        }
        return nil
    }

    // MARK: - 解析分享页

    /// 解析一条分享链接。走公开分享页，**不需要登录、不需要签名**。
    func resolve(_ text: String) async throws -> DouyinShare {
        guard let url = Self.extractLink(from: text) else { throw DouyinError.badLink }

        var request = URLRequest(url: url)
        request.setValue(Self.mobileAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DouyinError.http(http.statusCode)
        }

        // 分享页是 UTF-8；偶发 GBK 的情况退回 latin1，至少不崩
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""

        var share = DouyinShare()
        share.link = (response.url ?? url).absoluteString
        share.videoID = Self.firstMatch(#"/video/(\d+)"#, in: share.link) ?? ""

        share.title = Self.metaContent(html, property: "og:title")
            ?? Self.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html)
            ?? ""
        if share.title.isEmpty {
            share.title = Self.metaContent(html, name: "description") ?? ""
        }
        share.cover = Self.metaContent(html, property: "og:image") ?? ""

        // 作者名常在标题里出现： 「xxx on 抖音」/「xxx的抖音」
        if let author = Self.firstMatch(#"<meta[^>]+name="author"[^>]+content="([^"]*)""#, in: html) {
            share.author = author
        }

        share.title = Self.decodeHTMLEntities(share.title)
        share.author = Self.decodeHTMLEntities(share.author)

        guard !share.isEmpty || !share.videoID.isEmpty else {
            throw DouyinError.badLink
        }
        return share
    }

    // MARK: - 写操作（未接入）
    //
    // 点赞 / 收藏 / 评论 / 关注 / 发布 都需要上面那个签名，
    // 所以这里**故意不提供假实现** —— 发一个一定失败的请求回来，
    // 比明说"没接"更糟：用户会以为是自己账号或网络的问题。
    //
    // 想用的时候：实现 `DouyinSigner` 并赋给 `DouyinClient.shared.signer`，
    // 界面上的 `canWrite` 会自动变成 true，其他地方不用改。

    // MARK: - 小工具

    private static func metaContent(_ html: String, property: String) -> String? {
        firstMatch(#"<meta[^>]+property="\#(property)"[^>]+content="([^"]*)""#, in: html)
    }

    private static func metaContent(_ html: String, name: String) -> String? {
        firstMatch(#"<meta[^>]+name="\#(name)"[^>]+content="([^"]*)""#, in: html)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 分享页里的标题会带 `&amp;` `&#39;` 这类实体，转回来。
    private static func decodeHTMLEntities(_ text: String) -> String {
        var out = text
        let map = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (key, value) in map {
            out = out.replacingOccurrences(of: key, with: value)
        }
        return out
    }
}
