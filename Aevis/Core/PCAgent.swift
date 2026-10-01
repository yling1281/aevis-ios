import Foundation

/// 跟「Aevis 电脑助手」（电脑上那个 EXE）说话的那一层。
///
/// ## 为什么要有这一层
///
/// MCP 本身只解决「怎么把工具接进来」，但用户手上其实只有两样东西：
/// **电脑屏幕上那个 6 位码**，和**电脑的 IP**。中间那一串 ——
/// 「探测这台机器在不在 → 拿码换令牌 → 把令牌塞进 MCP 服务的请求头」——
/// 全部收在这里，界面那边就只管收两个输入框。
///
/// ## 为什么令牌不是可选的
///
/// 电脑那边的 `/mcp` 上挂着 `pc_shell`（能在那台电脑上跑任意命令）。
/// 服务是把电脑的令牌门装在**最外层**的：除了回环（电脑自己）之外，
/// 局域网来的请求一律要 `Authorization: Bearer <令牌>`。
/// 所以这里换到的令牌**必须**写进 MCP 服务的请求头，少一行就连不上 ——
/// 而且报的是 401，不是「服务没起来」，看日志时别被绕进去。
///
/// ## 全程只用局域网
///
/// 不经过任何服务器（这是用户明确定的）：手机和电脑得在同一个 WiFi。
/// 好处是画面延迟最低，而且配对码、令牌都出不了这个网。
enum PCAgent {

    /// 电脑助手默认端口。用户多半只填 IP，端口交给这个默认值。
    static let defaultPort = 8851

    // MARK: - 数据

    /// 一台电脑（`GET /pair.json`）
    struct Machine: Equatable {
        var device: String
        var host: String
        var port: Int
        /// 电脑**当前**的配对码。只用来显示/帮用户核对，不作为凭据。
        var code: String
    }

    /// 电脑上那台安卓手机的现状（`GET /phone.json`）
    struct PhoneStatus: Equatable {
        var connected: Bool
        var brand: String
        var model: String
        var android: String
        var currentApp: String
        var pairing: [Service]
        var connect: [Service]
        var hint: String
        var adbOK: Bool
        var adbError: String

        var summary: String {
            guard connected else { return "还没连上" }
            var text = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !android.isEmpty { text += " · Android \(android)" }
            if !currentApp.isEmpty { text += " · 前台 \(PCAgent.friendlyApp(currentApp))" }
            return text
        }
    }

    /// 前台应用的包名 → 人看得懂的名字。
    ///
    /// 直接把 `com.tencent.mobileqq` 摆出来，用户没法一眼确认「她现在到底在不在 QQ 里」，
    /// 而这恰恰是他唯一关心的那件事。认不出来的原样显示 —— 总比编一个错的好。
    static func friendlyApp(_ package: String) -> String {
        let name = package.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        let known: [String: String] = [
            "com.tencent.mobileqq": "QQ",
            "com.tencent.mm": "微信",
            "com.tencent.tim": "TIM",
            "com.ss.android.ugc.aweme": "抖音",
            "com.sina.weibo": "微博",
            "com.taobao.taobao": "淘宝",
            "com.eg.android.AlipayGphone": "支付宝",
            "com.netease.cloudmusic": "网易云音乐",
            "com.tencent.qqmusic": "QQ音乐",
            "tv.danmaku.bili": "哔哩哔哩",
            "com.xingin.xhs": "小红书",
            "com.android.settings": "系统设置",
            "com.android.systemui": "系统界面",
            "com.bbk.launcher2": "桌面",
            "com.android.chrome": "Chrome",
            "com.tencent.mtt": "QQ浏览器",
        ]
        if let hit = known[name] { return hit }
        // 认不出来就截短一点，至少还能看出是哪家做的
        return name.count > 28 ? String(name.prefix(28)) + "…" : name
    }

    /// mDNS 扫到的一条无线调试服务。
    ///
    /// ⚠️ 分两种，别混：`isPairing = true` 是**配对端口**，
    /// **只有手机屏幕上那个「使用配对码配对设备」弹窗开着时才广播**，
    /// 弹窗一关就没了。`isPairing = false` 是连接端口，无线调试开着就一直在。
    struct Service: Equatable, Identifiable {
        var host: String
        var port: Int
        var name: String
        var isPairing: Bool
        var id: String { "\(isPairing ? "p" : "c")-\(host)-\(port)" }
        var text: String { "\(host):\(port)" }
    }

    /// 配对手机的结果。
    struct PairOutcome: Equatable {
        var ok: Bool
        var error: String
        var device: String

        var message: String {
            if ok {
                return device.isEmpty ? "配好了。" : "配好了，已经连上 \(device)。"
            }
            return error.isEmpty ? "没配上。" : error
        }
    }

    /// 用户填进来的一串地址。
    struct Address: Equatable {
        var host: String
        var port: Int
        /// 扫码时顺带带过来的配对码（手输时是空的）。
        var code: String

        var text: String { "\(host):\(port)" }
    }

    // MARK: - 解析用户输入

    /// 用户填的地址可能是好几种写法，**全都得认**：
    ///
    /// - `192.168.1.10`                     ← 最常见，端口走默认
    /// - `192.168.1.10:8851`
    /// - `http://192.168.1.10:8851/mcp`     ← 从 MCP 那条复制过来的
    /// - `aevis://pc?host=…&port=…&code=…`  ← 扫 `/pair` 页面那个码来的
    ///
    /// 认不出来返回 nil，界面那边提示「地址看着不对」，
    /// 别拿着一个必然超时的地址让用户干等 6 秒。
    static func parse(_ raw: String) -> Address? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // ① 扫码：整串都在 query 里，连配对码一起带过来
        if let comps = URLComponents(string: text),
           comps.scheme?.lowercased() == "aevis" {
            let items = comps.queryItems ?? []
            func value(_ key: String) -> String {
                items.first { $0.name.lowercased() == key }?.value ?? ""
            }
            let host = value("host").trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return nil }
            let port = Int(value("port")) ?? defaultPort
            return Address(host: host, port: port, code: value("code"))
        }

        // ② 没写协议就补一个 —— 不补的话 URLComponents 把 `192.168.1.10:8851`
        //    里的 `192.168.1.10` 当成 scheme，host 会是空的
        var withScheme = text
        let lowered = text.lowercased()
        if !lowered.hasPrefix("http://") && !lowered.hasPrefix("https://") {
            withScheme = "http://" + text
        }
        guard let comps = URLComponents(string: withScheme),
              let host = comps.host, !host.isEmpty else { return nil }
        return Address(host: host, port: comps.port ?? defaultPort, code: "")
    }

    // MARK: - 探测

    /// 这台机器是不是「Aevis 电脑助手」。
    ///
    /// 光「连得上」不算 —— 同一个端口上可能是别的东西（路由器后台、别的服务）。
    /// 所以要认 `device` 这个字段，认不出来就明说，别让用户对着一个
    /// 「连不上」猜半天。
    static func probe(_ address: Address, timeout: TimeInterval = 6) async throws -> Machine {
        let json = try await getJSON(path: "/pair.json", address: address, timeout: timeout)
        guard json["ok"] as? Bool == true,
              let device = json["device"] as? String else {
            throw PCError.notAevisAgent
        }
        let host = (json["host"] as? String) ?? address.host
        let port = (json["port"] as? Int) ?? address.port
        return Machine(device: device, host: host, port: port,
                       code: (json["code"] as? String) ?? "")
    }

    // MARK: - 用配对码换令牌

    /// 拿 6 位码换一个长期令牌。换不到就是码不对/被限速。
    static func exchange(_ address: Address, code: String,
                         timeout: TimeInterval = 8) async throws -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { throw PCError.badCodeShape }

        let (status, json) = try await postJSON(
            path: "/pair/exchange",
            body: ["code": digits],
            address: address,
            timeout: timeout
        )
        switch status {
        case 200:
            guard let token = json["token"] as? String, !token.isEmpty else {
                throw PCError.notAevisAgent
            }
            return token
        case 403:
            throw PCError.badCode
        case 429:
            throw PCError.tooManyTries(wait: (json["wait"] as? Int) ?? 60)
        default:
            throw PCError.http(code: status, message: (json["error"] as? String) ?? "")
        }
    }

    // MARK: - 手机

    /// 电脑上那台手机现在什么状态（顺带把 mDNS 重扫一遍）。
    static func phoneStatus(_ address: Address,
                            timeout: TimeInterval = 12) async throws -> PhoneStatus {
        let json = try await getJSON(path: "/phone.json", address: address, timeout: timeout)

        func services(_ key: String, pairing: Bool) -> [Service] {
            (json[key] as? [[String: Any]] ?? []).compactMap { item in
                guard let host = item["host"] as? String,
                      let port = item["port"] as? Int ?? (item["port"] as? NSNumber)?.intValue
                else { return nil }
                return Service(host: host, port: port,
                               name: (item["name"] as? String) ?? "",
                               isPairing: pairing)
            }
        }

        return PhoneStatus(
            connected: json["connected"] as? Bool ?? false,
            brand: (json["brand"] as? String) ?? "",
            model: (json["model"] as? String) ?? "",
            android: (json["android"] as? String) ?? "",
            currentApp: (json["current_app"] as? String) ?? "",
            pairing: services("pairing", pairing: true),
            connect: services("connect", pairing: false),
            hint: (json["hint"] as? String) ?? "",
            adbOK: json["adb_ok"] as? Bool ?? true,
            adbError: (json["adb_error"] as? String) ?? ""
        )
    }

    /// 把手机上那个 6 位码交给电脑，让它去 `adb pair`。
    ///
    /// ⚠️ 这里是**手机自己的**配对码（跟电脑的配对码是两回事，虽然都长 6 位）。
    ///    而且电脑必须能扫到配对端口 —— 手机上那个弹窗得开着。
    static func pairPhone(_ address: Address, code: String,
                          service: Service? = nil,
                          timeout: TimeInterval = 40) async throws -> PairOutcome {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { throw PCError.badCodeShape }

        var body: [String: Any] = ["code": digits]
        if let service {
            body["host"] = service.host
            body["port"] = service.port
        }

        let (status, json) = try await postJSON(
            path: "/phone/pair", body: body, address: address, timeout: timeout
        )
        let ok = json["ok"] as? Bool ?? false
        if ok || status < 500 {
            return PairOutcome(
                ok: ok,
                error: (json["error"] as? String) ?? (json["hint"] as? String) ?? "",
                device: (json["device"] as? String) ?? (json["paired_with"] as? String) ?? ""
            )
        }
        throw PCError.http(code: status, message: (json["error"] as? String) ?? "")
    }

    /// 断开手机（**不删配对** —— 手机上那个授权是持久的，随时能连回来）。
    static func disconnectPhone(_ address: Address) async throws {
        _ = try await postJSON(path: "/phone/disconnect", body: [:],
                               address: address, timeout: 15)
    }

    // MARK: - MCP 服务项

    /// 从一台电脑生成一条 MCP 服务配置。
    ///
    /// 令牌走请求头而不是塞进 url：url 会被打进日志、也会出现在界面上，
    /// 而这个令牌等价于「能在这台电脑上跑命令」。
    static func serverConfig(name: String, machine: Machine, token: String) -> MCPServerConfig {
        var server = MCPServerConfig(
            name: name.isEmpty ? machine.device : name,
            url: "http://\(machine.host):\(machine.port)/mcp",
            headerLines: token.isEmpty ? "" : "Authorization: Bearer \(token)"
        )
        server.pcHost = machine.host
        server.pcPort = machine.port
        return server
    }

    // MARK: - HTTP 打底

    private static func makeSession(_ timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 4
        // 局域网里「连不上」就该立刻说连不上，不要挂着等网络变好 ——
        // 手机切到别的 WiFi 时会让界面卡在那里一动不动
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func baseURL(_ address: Address, path: String) -> URL? {
        URL(string: "http://\(address.host):\(address.port)\(path)")
    }

    private static func getJSON(path: String, address: Address,
                                timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = baseURL(address, path: path) else { throw PCError.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await send(request, timeout: timeout)
        return try decode(data: data, response: response)
    }

    private static func postJSON(path: String, body: [String: Any], address: Address,
                                 timeout: TimeInterval
    ) async throws -> (Int, [String: Any]) {
        guard let url = baseURL(address, path: path) else { throw PCError.badAddress }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request, timeout: timeout)
        let status = response.statusCode
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private static func send(_ request: URLRequest,
                             timeout: TimeInterval) async throws
        -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await makeSession(timeout).data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PCError.notAevisAgent }
            return (data, http)
        } catch let error as PCError {
            throw error
        } catch let error as URLError {
            throw PCError.offline(error)
        }
    }

    private static func decode(data: Data,
                               response: HTTPURLResponse) throws -> [String: Any] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // 连上了、也返回了东西，但不是 JSON —— 十有八九这个地址上跑的是别的东西
            throw PCError.notAevisAgent
        }
        guard response.statusCode == 200 else {
            throw PCError.http(code: response.statusCode,
                               message: (json["error"] as? String) ?? "")
        }
        return json
    }
}

// MARK: - 出错时说的话

/// 这些文案是**给用户看的**，所以每一条都要能指导下一步动作 ——
/// 「连接失败」这种话等于没说。
enum PCError: LocalizedError {
    case badAddress
    case badCodeShape
    case notAevisAgent
    case badCode
    case tooManyTries(wait: Int)
    case http(code: Int, message: String)
    case offline(URLError)

    var errorDescription: String? {
        switch self {
        case .badAddress:
            return "地址看着不对。填电脑的 IP 就行，比如 192.168.1.10 或 192.168.1.10:8851。"

        case .badCodeShape:
            return "配对码是 6 位数字，再看看电脑上那个码。"

        case .notAevisAgent:
            return "连上了，但那个地址上跑的不是「Aevis 电脑助手」。"
                 + "检查一下 IP 和端口（默认 \(PCAgent.defaultPort)）是不是电脑上那个。"

        case .badCode:
            return "配对码不对。电脑上的码可能会变，去 http://<电脑IP>:\(PCAgent.defaultPort)/pair 看一眼现在的。"

        case .tooManyTries(let wait):
            return "试太多次了，等 \(wait) 秒再试。（配对码只有 6 位，"
                 + "不限速的话几十秒就能暴力猜完，所以电脑那边会拦。）"

        case .http(let code, let message):
            let tail = message.isEmpty ? "" : "：\(message.prefix(120))"
            return "电脑返回了 HTTP \(code)\(tail)"

        case .offline(let error):
            return PCError.explain(error)
        }
    }

    /// 把 `URLError` 翻成「所以你现在该干什么」。
    private static func explain(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "连上了但一直没回应（超时）。看看电脑上那个窗口是不是被关了。"
        case .cannotConnectToHost, .cannotFindHost:
            // iOS 14 起，访问 192.168.x.x 需要「本地网络」权限，而且**被拒时
            // 系统不给任何专门的错误码**，表现就是连不上（有时连超时都不是）。
            // 所以这一条必须把那个设置项写进去，否则用户永远查不到原因。
            return "连不上这台电脑。四件事按顺序查："
                 + "① iPhone 设置 → 隐私与安全性 → 本地网络，Aevis 是不是开着的；"
                 + "② 手机和电脑在不在同一个 WiFi；"
                 + "③ 电脑上「Aevis 电脑助手」那个窗口还开着吗；"
                 + "④ IP 对不对（在电脑上打开 http://127.0.0.1:\(PCAgent.defaultPort)/pair 能看到局域网地址）。"
        case .notConnectedToInternet, .networkConnectionLost:
            return "网络断了。换回和电脑同一个 WiFi 再试。"
        case .appTransportSecurityRequiresSecureConnection:
            return "系统拦了这次明文连接（ATS）。这是 App 配置问题，不是你填错了。"
        case .dataNotAllowed:
            return "系统不让这个 App 走当前网络。去设置里看看是不是开了「无线局域网助理」"
                 + "或者限流。"
        default:
            // ⚠️ 这里**故意不列举**「本地网络权限被拒」那个错 —— 它不是
            //    URLError 里一个稳定的 case，写死了以后升级系统会编译不过。
            //    系统拒绝局域网时最常见的表现就是 cannotConnectToHost（超时都算不上），
            //    上面那条已经把「去设置 → 隐私与安全性 → 本地网络」写进去了。
            return "连不上：\(error.localizedDescription)"
        }
    }
}
