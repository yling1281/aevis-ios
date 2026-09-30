import Foundation

/// 一首歌。
struct MusicTrack: Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// 播放地址，拿到之前是空的（网易的地址是临时的，每次都要现取）
    var url: URL?
    /// 专辑封面。**要单独问一次接口才有**（见 `NeteaseClient.attachCovers`），
    /// 拿不到就是 nil —— 播放界面会退回一个渐变圆盘，不影响听歌。
    ///
    /// 给了默认值：这样 `MusicTrack(...)` 的老调用处不用跟着改一遍。
    var coverURL: URL? = nil
    /// 网易的收费标记：0 免费 / 1 会员专享 / 4 需要买专辑 / 8 低音质免费。
    /// 只用来把「为什么放不了」说准确 —— 光报一个错误码对用户没有意义。
    var fee: Int = 0

    var display: String {
        artist.isEmpty ? title : "\(artist) - \(title)"
    }

    /// 给用户看的收费说明，没有就是 nil。
    var feeNote: String? {
        switch fee {
        case 1: return "会员专享"
        case 4: return "需要购买专辑"
        case 8: return "非会员只能听低音质"
        default: return nil
        }
    }
}

enum NeteaseError: LocalizedError {
    case badResponse(String)
    /// HTTP 层失败。**必须把状态码和响应体带出来** ——
    /// 早先这里只写一句「HTTP 状态不对」，等于把唯一的线索扔掉了。
    case http(status: Int, body: String)
    case api(code: Int, message: String)
    case noPlayableURL(String)

    var errorDescription: String? {
        switch self {
        case let .badResponse(text):
            return "网易返回的内容看不懂：\(text.prefix(160))"
        case let .http(status, body):
            return "网易接口 HTTP \(status)：\(body.prefix(160))"
        case let .api(code, message):
            switch code {
            case 301:
                return "网易说要登录（code 301）。去「音乐」页更新一下 Cookie。"
            case -460:
                return "被网易的风控拦了（code -460）。过一会儿再试，或者换个网络。"
            case 50000005:
                return "网易拒绝了这次请求（code 50000005：签名或参数校验没过）。去「音乐」页点「诊断」看看原始返回。"
            default:
                return "网易接口返回 \(code)：\(message)"
            }
        case let .noPlayableURL(reason):
            return "这首歌现在放不了：\(reason)"
        }
    }
}

/// 网易云音乐的接口客户端。
///
/// **这里是逆向接入，没有官方 API。**
///
/// ## 两条通道，默认走明文
/// 网易实际上有两套接口：
///
/// - **明文**：`/api/xxx`，参数直接摆在 URL 上，不加密。
/// - **加密**：`/weapi/xxx`，请求体要过两层 AES-128-CBC 再包一层裸 RSA。
///
/// 2026-09-25 实测（`tools/netease_probe*.py` 三个探针就是干这个的）：
/// **加密通道已经被网易掐掉** —— 不管签名多正确、带不带 cookie、
/// 换成 eapi 还是 linuxapi，搜索都恒定返回 `{"code":50000005}`；
/// 而同一台机器、同一时刻走明文 `/api/search/get` 立刻搜到 335 条。
///
/// 所以默认通道改成明文；**加密那套代码保留**，作为兜底和对照。
///
/// 登录方式选的是**贴 Cookie** 而不是账号密码：
/// 账号密码登录要过验证码、要处理设备指纹，失败率高且一出错就卡死；
/// 而 Cookie 是在浏览器里正常登录一次就能拿到的东西，**最不容易白折腾**。
/// 而且实测**没登录也能搜索和试听**，登录只影响每日推荐和会员曲目。
final class NeteaseClient {

    static let shared = NeteaseClient()

    /// 走哪条通道。
    enum Channel: String {
        case plain
        case weapi

        var label: String {
            switch self {
            case .plain: return "明文接口"
            case .weapi: return "加密接口"
            }
        }
    }

    private let base = "https://music.163.com"
    private let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// Cookie 的唯一来源就是 AppSettings（存在钥匙串里）。
    /// 客户端不留自己的一份，省得两边不同步。
    private var cookie: String { AppSettings.shared.neteaseCookie }

    private init() {}

    var isLoggedIn: Bool { cookie.contains("MUSIC_U=") }

    /// 当前通道。存在 AppSettings 里，所以改完重启还在。
    var channel: Channel {
        get { Channel(rawValue: AppSettings.shared.neteaseChannel) ?? .plain }
        set { AppSettings.shared.neteaseChannel = newValue.rawValue }
    }

    func setCookie(_ raw: String) {
        AppSettings.shared.neteaseCookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signOut() {
        AppSettings.shared.neteaseCookie = ""
    }

    // MARK: - 搜索

    func search(_ keyword: String, limit: Int = 20) async throws -> [MusicTrack] {
        // ⚠️ 这三行 `step` 是"搜歌闪退"的定位器，别删：
        // 崩了之后黑匣子里最后停在哪个箭头，就知道死在哪一步。
        //（2026-09-30 就是这么定位到 `attachCovers` 拼 URL 崩的。）
        BlackBox.step("搜歌「\(keyword.prefix(30))」")
        let json = try await request(
            plain: ("/api/search/get", [
                "s": keyword, "type": "1", "offset": "0", "limit": "\(limit)"
            ]),
            encrypted: ("/weapi/cloudsearch/get/web", [
                "s": keyword, "type": 1, "limit": limit, "offset": 0, "total": true
            ])
        )
        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("搜索结果里没有 songs（\(Self.brief(json))）")
        }
        BlackBox.step("搜到 \(songs.count) 条，解析 + 补封面")
        return await attachCovers(to: Self.dedupe(songs.compactMap(Self.track(from:))))
    }

    /// 同一个 id 只留第一条。
    ///
    /// 网易云的搜索结果里偶尔会出现重复 id（同一首歌的不同版本/不同音质条目）——
    /// 界面上会看到两行长得一样，而且 SwiftUI 拿它当唯一标识时会出问题。
    private static func dedupe(_ tracks: [MusicTrack]) -> [MusicTrack] {
        var seen = Set<String>()
        var out: [MusicTrack] = []
        for track in tracks where seen.insert(track.id).inserted {
            out.append(track)
        }
        return out
    }

    // MARK: - 封面
    //
    // ⚠️ **明文搜索的返回里没有封面地址** —— 只给了一个 `album.picId` 数字，
    // 拼不出图来（加密版才有 `al.picUrl`）。所以封面必须单独问一次
    // `/api/v3/song/detail`。
    //
    // 好消息是它支持一次问多首（`c` 是一个 JSON 数组），所以整页结果只花一次请求。
    // 失败就静默跳过：播放界面会退回一个渐变圆盘，不影响听歌。

    /// 给一批歌补上封面地址。
    ///
    /// 🔴 **这里曾经是「搜歌必闪退」的案发现场**（2026-09-30）：
    /// `c` 的值长这样 `[{"id":123}]`，旧代码把方括号当"安全字符"放行、
    /// 再手工赋给 `percentEncodedQuery` → setter 校验不过 → ObjC 异常 → 进程当场死。
    /// `search` 本身没有方括号所以搜得到结果，**用户看到的就是"搜着搜着闪退"**。
    /// 现在整个 query 交给 `queryItems` 编码，这条路上不会再出现非法字符。
    func attachCovers(to tracks: [MusicTrack]) async -> [MusicTrack] {
        guard !tracks.isEmpty else { return tracks }
        let ids = tracks.prefix(60).map(\.id)
        let payload = "[" + ids.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"

        BlackBox.step("补封面（\(ids.count) 首）")
        guard let json = try? await plainRequest("/api/v3/song/detail", ["c": payload]),
              let songs = json["songs"] as? [[String: Any]] else {
            return tracks
        }

        var covers: [String: URL] = [:]
        for song in songs {
            guard let id = Self.idString(song["id"]),
                  let album = song["al"] as? [String: Any],
                  let text = album["picUrl"] as? String, !text.isEmpty,
                  let url = URL(string: text) else { continue }
            covers[id] = url
        }
        guard !covers.isEmpty else { return tracks }

        return tracks.map { track in
            guard let cover = covers[track.id] else { return track }
            var copy = track
            copy.coverURL = cover
            return copy
        }
    }

    // MARK: - 歌单与推荐

    func playlistDetail(_ id: String) async throws -> [MusicTrack] {
        let json = try await request(
            plain: ("/api/v6/playlist/detail", ["id": id, "n": "1000", "s": "8"]),
            encrypted: ("/weapi/v6/playlist/detail", ["id": id, "n": 1000, "s": 8])
        )
        guard let playlist = json["playlist"] as? [String: Any],
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("歌单里没有 tracks（\(Self.brief(json))）")
        }
        return await attachCovers(to: tracks.compactMap(Self.track(from:)))
    }

    func dailyRecommend() async throws -> [MusicTrack] {
        let json = try await request(
            plain: ("/api/discovery/recommend/songs", [:]),
            encrypted: ("/weapi/v2/discovery/recommend/songs", [:])
        )
        // 明文给的是 recommend，加密版给的是 data.dailySongs，两边都认
        let data = json["data"] as? [String: Any]
        let tracks = (data?["dailySongs"] as? [[String: Any]])
            ?? (json["recommend"] as? [[String: Any]])
            ?? []
        guard !tracks.isEmpty else {
            throw NeteaseError.badResponse("每日推荐里没有歌（\(Self.brief(json))）")
        }
        return await attachCovers(to: tracks.compactMap(Self.track(from:)))
    }

    // MARK: - 播放地址与歌词

    /// 取播放地址。网易给的是临时链接（`expi` 约 1200 秒），所以每次播放前都要现取。
    ///
    /// ⚠️ `ids` 的值是 `[123]` —— **带方括号**。这里同样踩过
    /// `percentEncodedQuery` 那个坑（历史 bug「点歌就闪退」）。
    /// 现在方括号由 `queryItems` 编成 `%5B%5D`，服务端解码后一样。
    func playableURL(for id: String, quality: Int = 320000) async throws -> URL {
        BlackBox.step("取播放地址 id=\(id)")
        let json = try await request(
            plain: ("/api/song/enhance/player/url", ["ids": "[\(id)]", "br": "\(quality)"]),
            encrypted: ("/weapi/song/enhance/player/url", ["ids": "[\(id)]", "br": quality])
        )
        guard let list = json["data"] as? [[String: Any]], let first = list.first else {
            throw NeteaseError.badResponse("播放地址返回是空的（\(Self.brief(json))）")
        }
        if let urlText = first["url"] as? String, !urlText.isEmpty, let url = URL(string: urlText) {
            return url
        }
        // 没拿到地址通常是版权或会员限制，网易把原因写在 code 里
        let code = (first["code"] as? Int) ?? 0
        let fee = (first["fee"] as? Int) ?? 0
        if let note = Self.feeNote(fee, code: code) {
            throw NeteaseError.noPlayableURL(note)
        }
        switch code {
        case 404:
            throw NeteaseError.noPlayableURL("这首歌没有版权，或者在你所在地区不开放。")
        case 403:
            throw NeteaseError.noPlayableURL("需要会员才能听。")
        default:
            throw NeteaseError.noPlayableURL(
                "网易没给地址（曲内 code \(code)、fee \(fee)）。去「音乐」页点「诊断」可以看原始返回。")
        }
    }

    func lyric(for id: String) async throws -> String {
        let json = try await request(
            plain: ("/api/song/lyric", ["id": id, "lv": "-1", "kv": "-1", "tv": "-1"]),
            encrypted: ("/weapi/song/lyric", ["id": id, "lv": -1, "kv": -1, "tv": -1])
        )
        if let lrc = json["lrc"] as? [String: Any], let text = lrc["lyric"] as? String {
            return text
        }
        return ""
    }

    // MARK: - 底层请求

    /// 一次请求同时给出两条通道的走法，谁先谁后看当前设置。
    ///
    /// 降级规则：**只有「通道本身不可用」才换一条重试**。
    /// 如果是「这首歌没版权」这种业务性失败，换通道也是白搭，直接抛。
    private func request(plain: (path: String, query: [String: String]),
                         encrypted: (path: String, params: [String: Any])) async throws -> [String: Any] {
        let order: [Channel] = channel == .plain ? [.plain, .weapi] : [.weapi, .plain]
        var firstError: Error?

        for attempt in order {
            do {
                switch attempt {
                case .plain:
                    return try await plainRequest(plain.path, plain.query)
                case .weapi:
                    return try await weapiRequest(encrypted.path, encrypted.params)
                }
            } catch {
                if firstError == nil { firstError = error }
                if let netease = error as? NeteaseError, case .noPlayableURL = netease {
                    break
                }
            }
        }
        throw firstError ?? NeteaseError.badResponse("两条通道都没走通")
    }

    /// 明文接口：GET + 参数挂在 query 上。
    ///
    /// ## 🔴 这里曾经是「搜歌必闪退」的元凶（2026-09-30 定位）
    ///
    /// 老写法是**自己拼 query 串**再赋给 `components.percentEncodedQuery`：
    ///
    /// ```swift
    /// components?.percentEncodedQuery = Self.queryString(query)   // ← 崩在这
    /// ```
    ///
    /// `percentEncodedQuery` 的 setter **会校验**：串里出现它不认的字符
    /// （`[` `]` 空格 `"` `%` `{` 等等）就抛 `NSInvalidArgumentException`
    /// —— 那是**未捕获的 ObjC 异常，进程当场终止**，没有任何补救机会。
    ///
    /// 要命的是这套代码**故意放行了方括号**（旧注释写「探针里用原始方括号能过」），
    /// 于是两条最常走的路全中：
    ///   - `attachCovers` → `c=[{"id":123}]`
    ///   - `playableURL` → `ids=[123]`
    /// 而 `search` 本身没有方括号，**所以结果其实已经搜回来了** ——
    /// 用户看到的是「搜了一下，然后闪退」，正是他报的「搜歌的时候」。
    ///
    /// ⚠️ **旧验证为什么是错的**：探针是 Python 写的，`urllib` **不做 URL 校验**，
    /// 裸方括号照样发得出去。本地怎么测都通，问题只在 App 里。
    /// （同一类坑的第二次复发，第一次是 `CharacterSet.alphanumerics` 那个 Unicode 问题。）
    ///
    /// ## 现在的写法
    /// 走 `queryItems`，**交给 Foundation 自己编码** —— 它按 RFC 3986 来，
    /// 不可能拼出非法串，这类崩溃从此不存在。
    /// 方括号会被编成 `%5B` / `%5D`，网易服务端 URL 解码后拿到的是同一个
    /// `[123]`，与 Python 探针实际发的字节一致。
    private func plainRequest(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard var components = URLComponents(string: base + path) else {
            throw NeteaseError.badResponse("路径拼错了：\(path)")
        }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw NeteaseError.badResponse("参数拼不出合法 URL：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        return try await send(request, label: "明文 \(path)")
    }

    /// 加密接口：weapi（两层 AES + 裸 RSA）。现在只当兜底和诊断对照用。
    private func weapiRequest(_ path: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: base + path + "?csrf_token=") else {
            throw NeteaseError.badResponse("路径拼错了：\(path)")
        }

        // csrf_token 放进**待加密的参数里**，而不是只挂在 query 上 ——
        // 标准实现是二者都有，之前只放 query 是这套代码的一处隐患。
        var payload = params
        payload["csrf_token"] = ""

        guard let encrypted = NeteaseCrypto.weapi(params: payload) else {
            throw NeteaseError.badResponse("加密失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(base, forHTTPHeaderField: "Referer")
        request.setValue(base, forHTTPHeaderField: "Origin")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        var body = "params=\(Self.formEncode(encrypted["params"] ?? ""))"
        body += "&encSecKey=\(Self.formEncode(encrypted["encSecKey"] ?? ""))"
        request.httpBody = Data(body.utf8)

        return try await send(request, label: "加密 \(path)")
    }

    /// 发出去，并把**能诊断的东西**都带进错误里。
    ///
    /// 这里同时往黑匣子记一笔 —— 「网易云一闪退就没了」这种情况，
    /// 黑匣子里那行就是唯一的现场（哪个接口、什么码、服务器说了什么）。
    private func send(_ request: URLRequest, label: String) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 网络层的原话比「获取失败」有用得多：超时、DNS、被 ATS 拦各有各的说法
            BlackBox.failure("网易云·\(label)", url: request.url?.absoluteString,
                             detail: error.localizedDescription)
            throw NeteaseError.badResponse("\(label) 连不上：\(error.localizedDescription)")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let text = String(decoding: data.prefix(600), as: UTF8.self)

        guard (200..<300).contains(status) else {
            BlackBox.failure("网易云·\(label)", url: request.url?.absoluteString,
                             status: status, detail: text)
            throw NeteaseError.http(status: status, body: text)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            BlackBox.failure("网易云·\(label) 不是 JSON", url: request.url?.absoluteString,
                             status: status, detail: text)
            throw NeteaseError.badResponse("\(label) 返回的不是 JSON：\(text.prefix(120))")
        }
        if let code = json["code"] as? Int, code != 200 {
            BlackBox.failure("网易云·\(label) 业务码 \(code)", url: request.url?.absoluteString,
                             status: status, detail: (json["message"] as? String) ?? "")
            throw NeteaseError.api(code: code, message: (json["message"] as? String) ?? "")
        }
        return json
    }

    // MARK: - 拼串与编码

    /// **只给 `weapiRequest` 的 form body 用**，⚠️ **不要拿它去拼 query**。
    ///
    /// 为什么改名（原名 `urlSafe`）：名字太中性，谁都可能顺手拿去拼 URL 串 ——
    /// 而 query 那条路现在是 `queryItems` 交给 Foundation 编码了（见 `plainRequest`）。
    /// 名字里带 `form` 就是为了让"拿去拼 query"这件事看起来不对。
    ///
    /// ⚠️ **绝对不能用 `CharacterSet.alphanumerics`** —— 那个是 **Unicode** 的，
    /// **中文也算「字母数字」**，所以中文关键词一个字符都不会被编码，
    /// 拼出来的 URL 直接非法。网易回的就是那句「格式错误」。
    ///
    /// 这个坑特别阴：本机探针是 Python 写的（`urllib.parse.quote` 老老实实编码中文），
    /// 所以**本地怎么测都是通的**，问题只出在 App 里。
    private static let formSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "abcdefghijklmnopqrstuvwxyz"
            + "0123456789"
            + "-._~"
    )

    /// weapi 的 form 编码。内容只有 base64 的 ASCII 字符，
    /// 但 `+` `/` `=` 这三个必须编掉 —— 尤其 `+`，不编会被服务端当成空格。
    private static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: formSafe) ?? text
    }

    private static func brief(_ json: [String: Any]) -> String {
        let code = (json["code"] as? Int).map { "code=\($0) " } ?? ""
        return code + "返回里有这些字段：" + json.keys.sorted().prefix(8).joined(separator: ",")
    }

    private static func feeNote(_ fee: Int, code: Int) -> String? {
        switch fee {
        case 1:
            return "这首歌是会员专享（fee 1），普通账号拿不到播放地址。"
        case 4:
            return "这首歌要买过专辑才能听（fee 4）。"
        case 8:
            return "这首歌非会员只能听低音质，但这次连低音质地址都没给（code \(code)）—— 多半是 Cookie 过期了。"
        default:
            return nil
        }
    }

    // MARK: - 解析

    /// 明文档和加密版给的字段名不一样：
    /// **明文用 `artists` / `album` / `duration`，加密版用 `ar` / `al` / `dt`**。
    ///
    /// 两种都必须认 —— 之前搜索走的是只认 `ar/al/dt` 的那个解析函数，
    /// 所以哪怕搜索成功，界面上的歌手和时长也全是空的。
    private static func track(from item: [String: Any]) -> MusicTrack? {
        guard let id = idString(item["id"]) else { return nil }

        let artists = names(from: item["ar"]) ?? names(from: item["artists"]) ?? []
        let album = (item["al"] as? [String: Any])?["name"] as? String
            ?? (item["album"] as? [String: Any])?["name"] as? String
            ?? ""
        // 两边的时长单位都是毫秒
        let duration = number(item["dt"]) ?? number(item["duration"]) ?? 0

        return MusicTrack(
            id: id,
            title: (item["name"] as? String) ?? "未命名",
            artist: artists.joined(separator: " / "),
            album: album,
            duration: duration / 1000.0,
            url: nil,
            fee: (item["fee"] as? Int) ?? 0
        )
    }

    private static func names(from value: Any?) -> [String]? {
        guard let list = value as? [[String: Any]] else { return nil }
        return list.compactMap { $0["name"] as? String }
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    private static func idString(_ value: Any?) -> String? {
        if let number = value as? Int { return String(number) }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    // MARK: - 诊断

    /// 一步诊断的结果。
    ///
    /// 这台电脑上没有 Xcode，**Swift 代码在本地根本跑不起来**，
    /// 所以把原始状态码和返回片段直接摊给用户看：他截个图发过来，
    /// 我就能知道是签名没过、被风控、还是接口又变了。
    struct DiagnosticStep: Identifiable {
        let id = UUID()
        var name: String
        var channel: String
        var result: String
        var ok: Bool
    }

    /// 依次打一遍关键接口，每一步都记下 HTTP 状态码和返回体片段。
    func diagnose() async -> [DiagnosticStep] {
        var steps: [DiagnosticStep] = []

        steps.append(await probe("搜索（明文）", channel: .plain) {
            try await self.plainRequest("/api/search/get", [
                "s": "周杰伦", "type": "1", "offset": "0", "limit": "3"
            ])
        })

        steps.append(await probe("搜索（加密，对照用）", channel: .weapi) {
            try await self.weapiRequest("/weapi/cloudsearch/get/web", [
                "s": "周杰伦", "type": 1, "limit": 3, "offset": 0, "total": true
            ])
        })

        steps.append(await probe("播放地址（明文）", channel: .plain) {
            try await self.plainRequest("/api/song/enhance/player/url", [
                "ids": "[33894312]", "br": "320000"
            ])
        })

        steps.append(await probe("歌词（明文）", channel: .plain) {
            try await self.plainRequest("/api/song/lyric", [
                "id": "33894312", "lv": "-1", "kv": "-1", "tv": "-1"
            ])
        })

        return steps
    }

    private func probe(_ name: String, channel: Channel,
                       _ body: () async throws -> [String: Any]) async -> DiagnosticStep {
        do {
            let json = try await body()
            let code = (json["code"] as? Int).map { "code=\($0)" } ?? "code 缺失"
            var extra = ""

            if let result = json["result"] as? [String: Any],
               let songs = result["songs"] as? [[String: Any]] {
                extra = " · 搜到 \(songs.count) 首"
            } else if let list = json["data"] as? [[String: Any]], let first = list.first {
                let hasURL = ((first["url"] as? String) ?? "").isEmpty ? "空" : "有"
                let inner = (first["code"] as? Int) ?? -999
                extra = " · 地址\(hasURL) · 曲内 code=\(inner) · fee=\((first["fee"] as? Int) ?? -1)"
            } else if let lrc = json["lrc"] as? [String: Any] {
                let text = (lrc["lyric"] as? String) ?? ""
                extra = " · 歌词 \(text.count) 字"
            }

            return DiagnosticStep(name: name, channel: channel.label,
                                  result: "通 · \(code)\(extra)", ok: true)
        } catch {
            return DiagnosticStep(name: name, channel: channel.label,
                                  result: error.localizedDescription, ok: false)
        }
    }
}
