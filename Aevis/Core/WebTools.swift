import Foundation

/// ta 的眼睛：能自己上网查、自己读页面。
///
/// 两个工具：
/// - `search_web` 用搜索引擎找
/// - `open_web_page` 把某个网页的正文抓下来读
///
/// 搜索引擎默认走 Bing，**不需要 API Key**。之所以不用那些"搜索 API"，
/// 是因为它们都要注册和付费，而用户不该为了问ta一句话去申请一个账号。
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
            上网搜索，返回几条结果的标题、摘要和链接。
            只要用户问的是你不知道的、或者会变的事，就直接用它去搜，别凭记忆编：
            比如新闻、价格、天气、比分、某个人或某件东西的近况、你不确定的事实。
            默认会多个引擎兜底，不用你换搜索源。
            搜到的摘要不够时，再用 open_web_page 打开具体那条网页读。
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

    /// 一条结果。给模型看的三样：标题、摘要、链接。
    private struct Hit {
        var title: String
        var snippet: String
        var url: String
    }

    /// 多引擎搜索。**顺序**：用户选的那个排第一（尊重他的设置），
    /// 后面按「必应 → DuckDuckGo → 搜狗 → 百度」兜底 ——
    /// 前一个**解析出 0 条**就换下一个。
    ///
    /// ⚠️ 为什么要兜底（用户 2026-10-05：「联网搜索有跟没有一样」）：
    ///    原来只打一个源、只认一种 HTML 结构。那个源一改版 ——
    ///    或者对某些关键词弹人机校验 —— 用户看到的就是「没搜到」，
    ///    而他无从知道是搜索坏了还是真没结果。现在改成逐级换源，
    ///    并且**每一步都写进黑匣子**，让「这次没搜成」这件事可被看见。
    static func search(_ query: String, count: Int) async -> String {
        let settings = AppSettings.shared
        let preferred = settings.searchSources.first { $0.name == settings.activeSearchSource }
            ?? settings.searchSources.first
        let chain = fallbackChain(preferred: preferred)

        var notes: [String] = []
        var lastHTML: String?
        var lastSource: SearchSource?

        for source in chain {
            guard let url = source.url(for: query) else {
                notes.append("「\(source.name)」的地址模板里没有 {q}")
                continue
            }

            let html: String
            do {
                html = try await fetch(url)
            } catch {
                notes.append("「\(source.name)」连不上")
                BlackBox.failure("联网搜索 · \(source.name) 请求失败",
                                 url: url.absoluteString,
                                 detail: error.localizedDescription)
                continue
            }

            lastHTML = html
            lastSource = source

            let hits = results(from: html, engine: source, limit: count)
            guard !hits.isEmpty else {
                notes.append("「\(source.name)」没解析出结果")
                BlackBox.log("· 联网搜索 · \(source.name) 解析 0 条（关键词 \(query.count) 字）")
                continue
            }

            BlackBox.network("联网搜索 · \(source.name) 命中 \(hits.count) 条",
                             url: url.absoluteString)
            return render(source: source, query: query, hits: hits)
        }

        // 全部引擎都没给出列表 —— 把最后抓到的那张页面正文读给ta（老行为），
        // 并把「这次没搜成」记进黑匣子，让不可见变可见。
        let detail = notes.joined(separator: "；")
        BlackBox.failure("联网搜索 · 全部引擎失败（\(chain.count) 个）", detail: detail)

        if let html = lastHTML, let source = lastSource {
            let readable = plainText(from: html)
            if readable.count > 200 {
                return "「\(source.name)」的结果页没能解析成列表，直接把正文读给你（前 2500 字）：\n\n"
                    + String(readable.prefix(2500))
            }
        }
        return "这次没搜到（试了 \(chain.count) 个引擎：\(detail)）。"
            + "换个说法再试，或者把具体网址给我，我直接打开读。"
    }

    /// 引擎顺序：用户选的排第一，去掉重复后接上默认兜底链。
    private static func fallbackChain(preferred: SearchSource?) -> [SearchSource] {
        // 默认兜底链。搜狗 / 百度是给「必应被挡或改版」时留的后路。
        let defaults = [
            SearchSource(name: "必应", template: "https://www.bing.com/search?q={q}&setlang=zh-CN"),
            SearchSource(name: "DuckDuckGo", template: "https://duckduckgo.com/html/?q={q}"),
            SearchSource(name: "搜狗", template: "https://www.sogou.com/web?query={q}"),
            SearchSource(name: "百度", template: "https://www.baidu.com/s?wd={q}")
        ]
        var chain: [SearchSource] = []
        var seen = Set<String>()
        let ordered = [preferred].compactMap { $0 } + defaults
        for source in ordered where !seen.contains(source.template) {
            seen.insert(source.template)
            chain.append(source)
        }
        return chain
    }

    /// 把结果排成模型好读的样子：序号 + 标题 + 摘要 + 链接。
    private static func render(source: SearchSource, query: String, hits: [Hit]) -> String {
        let lines = hits.enumerated().map { index, hit -> String in
            var line = "\(index + 1). \(hit.title)"
            if !hit.snippet.isEmpty { line += "\n   \(hit.snippet)" }
            line += "\n   \(hit.url)"
            return line
        }
        return "用「\(source.name)」搜「\(query)」的结果：\n" + lines.joined(separator: "\n")
    }

    // MARK: - 解析搜索结果
    //
    // ⚠️ 这里是整个「联网搜索」最脆的一环：搜索结果页是 HTML，结构随版本变、
    //    还可能弹人机校验。所以**每个引擎一套专属解析 + 一套通用锚点兜底**，
    //    任何一层解析出 0 条就换下一个引擎 —— 而不是把「没搜到」丢给用户。

    private static func results(from html: String, engine: SearchSource, limit: Int) -> [Hit] {
        let template = engine.template.lowercased()
        let host = URL(string: engine.template.replacingOccurrences(of: "{q}", with: "x"))?.host ?? ""

        var hits: [Hit] = []
        if template.contains("bing.com") {
            hits = bing(html)
        } else if template.contains("duckduckgo") {
            hits = duck(html)
        } else if template.contains("sogou.com") {
            hits = sogou(html)
        } else if template.contains("baidu.com") {
            hits = baidu(html)
        }
        // 专属解析没结果 → 通用锚点扫描（换版或自定义源都能凑合）
        if hits.isEmpty {
            hits = generic(html, engineHost: host)
        }
        return Array(hits.prefix(limit))
    }

    /// 必应：`<li class="b_algo">` 里是 `<h2><a href>标题</a></h2>` 加一段摘要。
    private static func bing(_ html: String) -> [Hit] {
        let raw = matches(
            #"<li[^>]*class="b_algo[^"]*".*?<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>(.*?)</li>"#,
            in: html
        )
        return raw.compactMap { item in
            guard item.count > 3 else { return nil }
            let url = absolute(item[1], host: "www.bing.com")
            let title = plainText(from: item[2])
            guard !title.isEmpty, !url.isEmpty else { return nil }
            return Hit(title: title, snippet: clean(item[3]), url: url)
        }
    }

    /// DuckDuckGo（html 版）：结果链接带 `class="result__a"`，摘要在 `result__snippet`。
    private static func duck(_ html: String) -> [Hit] {
        let links = matches(#"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        let snippets = matches(#"<a[^>]*class="result__snippet"[^>]*>(.*?)</a>"#, in: html)
        return links.enumerated().compactMap { index, item in
            guard item.count > 2 else { return nil }
            let url = decodeDuckDuckGo(item[1])
            let title = plainText(from: item[2])
            guard !title.isEmpty, url.hasPrefix("http") else { return nil }
            var snippet = ""
            if index < snippets.count, snippets[index].count > 1 {
                snippet = clean(snippets[index][1])
            }
            return Hit(title: title, snippet: snippet, url: url)
        }
    }

    /// 搜狗：标题在 `<h3 class="vr-title"><a href>…</a></h3>`，链接常是站内 /link 跳转。
    private static func sogou(_ html: String) -> [Hit] {
        let raw = matches(
            #"<h3[^>]*class="vr-title"[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
            in: html
        )
        return raw.compactMap { item in
            guard item.count > 2 else { return nil }
            let url = absolute(item[1], host: "www.sogou.com")
            let title = plainText(from: item[2])
            guard !title.isEmpty, !url.isEmpty else { return nil }
            return Hit(title: title, snippet: "", url: url)
        }
    }

    /// 百度：`<h3 … mu="真实地址">` 比 `/link?url=` 的跳转好认，优先取 mu。
    private static func baidu(_ html: String) -> [Hit] {
        let raw = matches(#"<h3([^>]*)>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>\s*</h3>"#, in: html)
        let abstracts = matches(#"<div[^>]*class="c-abstract[^"]*"[^>]*>(.*?)</div>"#, in: html)
        return raw.enumerated().compactMap { index, item in
            guard item.count > 3 else { return nil }
            let url = firstMatch(#"mu="([^"]+)""#, in: item[1])
                ?? absolute(item[2], host: "www.baidu.com")
            let title = plainText(from: item[3])
            guard !title.isEmpty, !url.isEmpty else { return nil }
            var snippet = ""
            if index < abstracts.count, abstracts[index].count > 1 {
                snippet = clean(abstracts[index][1])
            }
            return Hit(title: title, snippet: snippet, url: url)
        }
    }

    /// 通用兜底：把页面里的外链当结果 —— 标题取锚文本，摘要留空
    /// （宁可少给摘要，也别把导航文字混进来）。
    private static func generic(_ html: String, engineHost: String) -> [Hit] {
        let raw = matches(#"<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: html)
        var hits: [Hit] = []
        var seen = Set<String>()
        for item in raw {
            guard item.count > 2 else { continue }
            let url = absolute(item[1], host: engineHost)
            let title = plainText(from: item[2])
            guard title.count >= 4, isResultURL(url, engineHost: engineHost) else { continue }
            if seen.contains(url) { continue }
            seen.insert(url)
            hits.append(Hit(title: String(title.prefix(120)), snippet: "", url: url))
        }
        return hits
    }

    // MARK: - 解析小工具

    /// 摘要清洗：HTML → 纯文本，太长的截断（一次给 240 字够模型判断了）。
    private static func clean(_ htmlFragment: String) -> String {
        let text = plainText(from: htmlFragment)
        return text.count > 240 ? String(text.prefix(240)) : text
    }

    /// 相对地址补成绝对地址；`//host/…` 补成 https。
    private static func absolute(_ href: String, host: String) -> String {
        let value = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { return "https:" + value }
        if value.hasPrefix("/") { return "https://\(host)\(value)" }
        return value
    }

    /// DuckDuckGo 的 html 版结果链接长这样：
    /// `//duckduckgo.com/l/?uddg=<百分号编码的真实地址>&rut=…` —— 把 `uddg` 拆出来。
    private static func decodeDuckDuckGo(_ href: String) -> String {
        let full = absolute(href, host: "duckduckgo.com")
        guard let range = full.range(of: "uddg=") else { return full }
        let tail = full[range.upperBound...]
        let encoded = tail.split(separator: "&").first.map(String.init) ?? String(tail)
        return encoded.removingPercentEncoding ?? full
    }

    /// 看起来像不像一条「结果链接」（排掉引擎站内链接、锚点、脚本）。
    private static func isResultURL(_ url: String, engineHost: String) -> Bool {
        let lower = url.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("#") { return false }
        // 引擎自己的跳转链接（/link?url=…）也算一条结果
        if lower.contains("/link?") { return true }
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return false }
        let engine = engineHost.lowercased()
        if host == engine || host.hasSuffix("." + engine) { return false }
        let engineOwned = ["bing.com", "duckduckgo.com", "sogou.com", "baidu.com",
                           "microsoft.com", "msn.com", "go.microsoft.com"]
        if engineOwned.contains(where: { host.hasSuffix($0) }) { return false }
        return true
    }

    /// 第一个捕获组（没有捕获组时返回整体匹配）。给「从一段属性里抠一个值」用。
    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let index = match.numberOfRanges > 1 ? 1 : 0
        guard let captured = Range(match.range(at: index), in: text) else { return nil }
        return String(text[captured])
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
