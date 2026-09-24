import Foundation

/// TA 的眼睛：能自己上网查、自己读页面。
///
/// 两个工具：
/// - `search_web` 用搜索引擎找
/// - `open_web_page` 把某个网页的正文抓下来读
///
/// 搜索引擎默认走 Bing，**不需要 API Key**。之所以不用那些"搜索 API"，
/// 是因为它们都要注册和付费，而用户不该为了问她一句话去申请一个账号。
extension DeviceTools {

    static var webTools: [DeviceTool] {
        [searchTool, openPageTool]
    }

    // MARK: - 搜索

    private static var searchTool: DeviceTool {
        DeviceTool(
            name: "search_web",
            title: "上网查了查",
            description: """
            用搜索引擎查资料，返回几条结果的标题、链接和摘要。
            用户问的事你不知道、或者需要最新信息的（新闻、价格、某个人、某个东西是什么）用它。
            拿到结果后如果摘要不够，可以再用 open_web_page 打开具体页面读。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "搜索关键词"],
                    "count": ["type": "integer", "description": "要几条结果，默认 5，最多 10"]
                ],
                "required": ["query"]
            ]
        ) { args in
            guard let query = args["query"] as? String,
                  !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "没给搜索关键词。"
            }
            let count = min(max((args["count"] as? Int) ?? 5, 1), 10)
            return await WebReader.search(query, count: count)
        }
    }

    // MARK: - 读网页

    private static var openPageTool: DeviceTool {
        DeviceTool(
            name: "open_web_page",
            title: "打开了一个网页",
            description: """
            把某个网页的正文抓成纯文本读一遍。搜索结果的摘要不够、或者用户直接给了链接时用它。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "要打开的网页地址，要带 https://"]
                ],
                "required": ["url"]
            ]
        ) { args in
            guard let url = args["url"] as? String, !url.isEmpty else {
                return "没给网页地址。"
            }
            return await WebReader.readPage(url)
        }
    }
}

/// 抓网页、搜索、把 HTML 洗成能读的文字。
enum WebReader {

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // MARK: - 搜索

    static func search(_ query: String, count: Int) async -> String {
        // 搜索源由用户选，默认必应
        let settings = AppSettings.shared
        let source = settings.searchSources.first { $0.name == settings.activeSearchSource }
            ?? settings.searchSources.first
            ?? SearchSource.builtIn[0]

        guard let url = source.url(for: query) else {
            return "搜索地址拼错了（搜索源「\(source.name)」的模板要包含 {q}）。"
        }

        let html: String
        do {
            html = try await fetch(url)
        } catch {
            return "用「\(source.name)」搜索失败：\(error.localizedDescription)"
        }

        // 标题 + 链接（先按必应/通用搜索页的结构抓）
        let links = matches(
            #"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            in: html
        )
        // 摘要
        let snippets = matches(#"<p[^>]*>(.*?)</p>"#, in: html)

        guard !links.isEmpty else {
            // 换了搜索源、结构不一样时抓不到列表。
            // 与其说「没搜到」，不如把页面正文给她读 —— 至少不白跑一趟。
            let readable = plainText(from: html)
            guard readable.count > 200 else {
                return "用「\(source.name)」没抓到结果（可能是这个源需要登录，或者结构变了）。换回必应试试。"
            }
            return "「\(source.name)」的结果页我抓不成列表，直接读正文给你（前 2500 字）：\n\n"
                + String(readable.prefix(2500))
        }

        var lines: [String] = []
        for (index, link) in links.prefix(count).enumerated() {
            let address = link.count > 1 ? link[1] : ""
            let title = link.count > 2 ? plainText(from: link[2]) : ""
            var line = "\(index + 1). \(title)\n   \(address)"
            if index < snippets.count, snippets[index].count > 1 {
                let snippet = plainText(from: snippets[index][1])
                if !snippet.isEmpty {
                    line += "\n   \(snippet.prefix(200))"
                }
            }
            lines.append(line)
        }
        return "用「\(source.name)」搜「\(query)」的结果：\n" + lines.joined(separator: "\n")
    }

    // MARK: - 读页面

    static func readPage(_ address: String) async -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") {
            text = "https://" + text
        }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            return "这个网址看不懂：\(address)"
        }

        do {
            let html = try await fetch(url)
            let body = plainText(from: html)
            guard !body.isEmpty else {
                return "这个页面抓下来是空的（可能是需要登录，或者内容靠脚本渲染）。"
            }
            return "\(host) 的正文（截取前 3000 字）：\n\n" + String(body.prefix(3000))
        } catch {
            return "打开失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 底层

    private static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "服务器返回 \(http.statusCode)"])
        }

        // 网页编码不一定是 UTF-8，先试 UTF-8 再退回 GB18030（国内站点常见）
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let text = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// HTML → 能读的纯文本。
    static func plainText(from html: String) -> String {
        var text = html
        for pattern in [
            "(?is)<script.*?</script>",
            "(?is)<style.*?</style>",
            "(?is)<head.*?</head>",
            "(?is)<!--.*?-->"
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?is)<(br|/p|/div|/li|/tr)[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)

        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&hellip;": "…"
        ]
        for (key, value) in entities {
            text = text.replacingOccurrences(of: key, with: value)
        }

        text = text.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 返回每个匹配的所有捕获组（第 0 组是整体匹配）。
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { result in
            (0..<result.numberOfRanges).map { index -> String in
                guard let captured = Range(result.range(at: index), in: text) else { return "" }
                return String(text[captured])
            }
        }
    }
}
