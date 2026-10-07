import Foundation

/// ta 在**真的网页上**动手的那几个工具。
///
/// 和 `WebTools`（`search_web` / `open_web_page`）的分工：
/// - `WebTools` 是「抓 HTML 读一遍」——只读、外面看不见、点不了；
/// - 这里这几个是**真的驱动那台浏览器**——用户看得见 ta 在点哪、填什么，
///   而且能真下到购物车、真搜到结果。
///
/// 🔴 一条硬红线（老板原话：「付款、下单那最后一步绝对不许 ta 代劳」）：
///    付款 / 下单的按钮**在 `BrowserSession.click` 的 JS 里就拦死**，
///    不是只写在提示词里 —— 拦到之后才由工具返回那句「让他自己点一下」。
extension DeviceTools {

    /// ta 的浏览器工具。**不要**并进 `webTools`（那会跟分类开关打架）。
    static var browserTools: [DeviceTool] {
        [browserOpenTool, browserReadTool, browserClickTool,
         browserTypeTool, browserScrollTool, browserBackTool]
    }

    // MARK: - 打开网页

    private static var browserOpenTool: DeviceTool {
        DeviceTool(
            name: "browser_open",
            title: "打开了网页",
            description: """
            在真的网站上打开一个页面 —— 用的是 App 里那台浏览器，用户看得见同一页，
            他也能随时自己上手。要买东西、要点外卖、要查东西时，先用它把站打开。

            参数二选一：
            - url：一个地址，必须带 http:// 或 https://。
            - site：网站名（淘宝 / 天猫 / 京东 / 拼多多 / 美团 / 饿了么 / 百度 / 必应），
              打开的是那个站的首页；url 和 site 都不给时默认开淘宝。

            这是真的在网页上操作，不是模拟。打开之后先用 browser_read 看这一页有什么，
            再用 browser_click 点、browser_type 打字 —— 要搜索就往搜索框里打字、
            再点搜索按钮，不要靠猜网址。

            注意：付款、提交订单这最后一步绝对不要替他点 —— 把页面停在待付款，
            然后让他自己点一下。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "要打开的网址，必须带 http:// 或 https://。和 site 二选一。"
                    ],
                    "site": [
                        "type": "string",
                        "description": "网站名：淘宝 / 天猫 / 京东 / 拼多多 / 美团 / 饿了么 / 百度 / 必应。不给 url 时用它，默认淘宝。"
                    ],
                    "title": [
                        "type": "string",
                        "description": "给这个页面起个名（可选），显示在浏览器顶部。"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            let session = BrowserSession.shared
            let rawURL = (args["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rawSite = (args["site"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = args["title"] as? String

            if let rawURL, !rawURL.isEmpty {
                guard let parsed = URL(string: rawURL),
                      let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    return "这个地址开不了：\(rawURL)。只能开 http 或 https 的网址，"
                        + "比如 https://m.taobao.com。"
                }
                return await session.open(url: parsed, title: title)
            }

            guard let target = homepageURL(for: rawSite) else {
                return "我能开的站有：" + availableSiteNames.joined(separator: "、")
                    + "。说一个站名，或者直接给一个 http/https 的网址。"
            }
            return await session.open(url: target, title: title)
        }
    }

    // MARK: - 看当前页

    private static var browserReadTool: DeviceTool {
        DeviceTool(
            name: "browser_read",
            title: "看了看当前网页",
            description: """
            把当前网页上「能点 / 能填」的东西列出来，每个带一个编号 ——
            再用 browser_click（点）或 browser_type（填）时，就用这些编号指。
            还会给出页面上的文字，够你判断现在到哪一步了。

            每次点 / 翻页之后页面都会变，所以动手之前先 browser_read 看一眼，
            别照着上一次的编号乱点。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "最多列几个可点 / 可填的东西，默认 60，最多 60。"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            let limit = min(max((args["limit"] as? Int) ?? 60, 1), 60)
            let session = BrowserSession.shared
            return await session.readPage(limit: limit)
        }
    }

    // MARK: - 点

    private static var browserClickTool: DeviceTool {
        DeviceTool(
            name: "browser_click",
            title: "在网页上点了一下",
            description: """
            在**真的网页**上点一下某个元素 —— 编号来自 browser_read 里那个 [数字]。
            这是真的在点，用户看得见同一页（他随时能自己上手）。

            点之前先 browser_read 看当前页、拿准编号；点完多半会跳页，
            所以你之后要再 read 一次看新页面。

            注意：付款、提交订单这最后一步绝对不要替他点 —— 把页面停在待付款，
            然后让他自己点一下。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "index": [
                        "type": "integer",
                        "description": "要点的元素编号（来自 browser_read 里那个 [数字]）。"
                    ],
                    "why": [
                        "type": "string",
                        "description": "你为什么点它，一句话（可选）。"
                    ]
                ],
                "required": ["index"]
            ]
        ) { args in
            let session = BrowserSession.shared
            guard let rawIndex = args["index"], let index = intValue(rawIndex) else {
                return "没给要点第几个（index）。先 browser_read 看一眼，上面有编号。"
            }
            return await session.click(index: index)
        }
    }

    // MARK: - 填

    private static var browserTypeTool: DeviceTool {
        DeviceTool(
            name: "browser_type",
            title: "在网页上填了内容",
            description: """
            往**真的网页**上的某个输入框里填字 —— 编号来自 browser_read 里那个带 field 的 [数字]。
            要搜索就是这样：先 browser_type 把关键词打进搜索框，再 browser_click 点搜索按钮，
            不要靠猜搜索结果的网址。

            密码框它不会填（会告诉你那个是密码框）。填完不会跳页，所以填完可以再 read 确认一下。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "index": [
                        "type": "integer",
                        "description": "要填的输入框编号（browser_read 里带 field 的那个 [数字]）。"
                    ],
                    "text": [
                        "type": "string",
                        "description": "要填进去的文字。"
                    ]
                ],
                "required": ["index", "text"]
            ]
        ) { args in
            let session = BrowserSession.shared
            guard let rawIndex = args["index"], let index = intValue(rawIndex) else {
                return "没给要填哪个框（index）。先 browser_read 看一眼，带 field 的那个编号。"
            }
            guard let text = args["text"] as? String, !text.isEmpty else {
                return "没给要填的内容（text）。"
            }
            return await session.type(index: index, text: text)
        }
    }

    // MARK: - 翻页

    private static var browserScrollTool: DeviceTool {
        DeviceTool(
            name: "browser_scroll",
            title: "把网页往下翻",
            description: """
            把当前网页往下（或往上）翻几屏。列表页往下翻会加载出更多商品 / 结果，
            想看更多就翻一翻，翻完再 browser_read 看新出来的内容。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "direction": [
                        "type": "string",
                        "description": "往下还是往上，down 或 up，默认 down。"
                    ],
                    "times": [
                        "type": "integer",
                        "description": "翻几屏，1 到 5，默认 1。"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            let direction = (args["direction"] as? String) ?? "down"
            let times = min(max((args["times"] as? Int) ?? 1, 1), 5)
            let session = BrowserSession.shared
            return await session.scroll(direction: direction, times: times)
        }
    }

    // MARK: - 后退

    private static var browserBackTool: DeviceTool {
        DeviceTool(
            name: "browser_back",
            title: "网页后退了一页",
            description: """
            在当前网页里后退一页（比如点进商品详情之后想回列表）。退完要再 browser_read
            看一遍，因为页面已经变了。
            """,
            parameters: emptyParameters()
        ) { _ in
            let session = BrowserSession.shared
            return await session.back()
        }
    }

    // MARK: - 站点表与参数小工具

    /// 支持的站点 —— **只放首页，不许猜深链**（深链随时会变，猜错了等于给用户一个白屏）。
    /// 要搜什么，靠 `browser_type` 往搜索框打字 + `browser_click` 点搜索，不靠拼 URL。
    private static let siteHomepages: [(keys: [String], name: String, url: String)] = [
        (["淘宝", "taobao"], "淘宝", "https://m.taobao.com"),
        (["天猫", "tmall"], "天猫", "https://m.tmall.com"),
        (["京东", "jd"], "京东", "https://m.jd.com"),
        (["拼多多", "pinduoduo", "pdd"], "拼多多", "https://mobile.yangkeduo.com"),
        (["美团", "meituan"], "美团", "https://i.meituan.com"),
        (["饿了么", "ele", "eleme"], "饿了么", "https://m.ele.me"),
        (["百度", "baidu"], "百度", "https://www.baidu.com"),
        (["必应", "bing"], "必应", "https://www.bing.com")
    ]

    /// 站点名的中文列表（错误提示里用）。
    private static var availableSiteNames: [String] {
        siteHomepages.map { $0.name }
    }

    /// 把 `site` 参数解析成首页地址。空 / 认不出时：空走默认（淘宝），认不出返回 nil。
    private static func homepageURL(for site: String?) -> URL? {
        let trimmed = (site ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = (trimmed.isEmpty ? "淘宝" : trimmed).lowercased()
        for entry in siteHomepages where entry.keys.contains(where: { wanted.contains($0.lowercased()) }) {
            return URL(string: entry.url)
        }
        return nil
    }

    /// 模型的参数可能是数字、字符串数字、NSNumber，都收。
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        if let number = value as? Double { return Int(number) }
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
