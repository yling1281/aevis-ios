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

    var display: String {
        artist.isEmpty ? title : "\(artist) - \(title)"
    }
}

enum NeteaseError: LocalizedError {
    case notLoggedIn
    case badResponse(String)
    case api(code: Int, message: String)
    case noPlayableURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "还没有登录网易云。去「音乐」里把网页版的 Cookie 贴进来。"
        case let .badResponse(text):
            return "网易返回的内容看不懂：\(text.prefix(80))"
        case let .api(code, message):
            switch code {
            case 301:
                return "网易说需要登录（301）。Cookie 可能过期了，重新贴一次。"
            case -460:
                return "被网易的风控拦了（-460）。等一会儿再试，或者换一个网络。"
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
/// **这里是逆向接入，没有官方 API**：请求体要用 `NeteaseCrypto` 加密，
/// 播放地址是临时的（每次播放前现取），而且**网易一改协议这里就会失效**。
/// 所以它被单独关在一个文件里，坏了只修这一处，不影响别的功能。
///
/// 登录方式选的是**贴 Cookie** 而不是账号密码：
/// 账号密码登录要过验证码、要处理设备指纹，失败率高且一出错就卡死；
/// 而 Cookie 是在浏览器里正常登录一次就能拿到的东西，**最不容易白折腾**。
final class NeteaseClient {

    static let shared = NeteaseClient()

    private let base = "https://music.163.com"
    private let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    /// Cookie 的唯一来源就是 AppSettings（存在钥匙串里）。
    /// 客户端不留自己的一份，省得两边不同步。
    private var cookie: String { AppSettings.shared.neteaseCookie }

    private init() {}

    var isLoggedIn: Bool { cookie.contains("MUSIC_U=") }

    func setCookie(_ raw: String) {
        AppSettings.shared.neteaseCookie = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func signOut() {
        AppSettings.shared.neteaseCookie = ""
    }

    // MARK: - 搜索

    func search(_ keyword: String, limit: Int = 20) async throws -> [MusicTrack] {
        let json = try await post(
            path: "/weapi/cloudsearch/get/web",
            params: ["s": keyword, "type": 1, "limit": limit, "offset": 0]
        )
        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("搜索结果里没有 songs")
        }
        return songs.compactMap(Self.track(fromSearchItem:))
    }

    // MARK: - 歌单与推荐

    func playlistDetail(_ id: String) async throws -> [MusicTrack] {
        let json = try await post(
            path: "/weapi/v6/playlist/detail",
            params: ["id": id, "n": 1000, "s": 8]
        )
        guard let playlist = json["playlist"] as? [String: Any],
              let tracks = playlist["tracks"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("歌单里没有 tracks")
        }
        return tracks.compactMap(Self.track(fromSongItem:))
    }

    func dailyRecommend() async throws -> [MusicTrack] {
        let json = try await post(path: "/weapi/v2/discovery/recommend/songs", params: [:])
        guard let data = json["data"] as? [String: Any],
              let tracks = data["dailySongs"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("每日推荐里没有 dailySongs")
        }
        return tracks.compactMap(Self.track(fromSongItem:))
    }

    // MARK: - 播放地址与歌词

    /// 取播放地址。网易给的是临时链接，所以每次播放前都要现取。
    func playableURL(for id: String, quality: Int = 320000) async throws -> URL {
        let json = try await post(
            path: "/weapi/song/enhance/player/url",
            params: ["ids": "[\(id)]", "br": quality]
        )
        guard let list = json["data"] as? [[String: Any]], let first = list.first else {
            throw NeteaseError.badResponse("播放地址返回是空的")
        }
        if let urlText = first["url"] as? String, let url = URL(string: urlText) {
            return url
        }
        // 没拿到地址通常是版权或会员限制，网易会把原因写在 code 里
        let code = (first["code"] as? Int) ?? 0
        switch code {
        case 404:
            throw NeteaseError.noPlayableURL("这首歌没有版权，或者在你所在地区不开放。")
        case 403:
            throw NeteaseError.noPlayableURL("需要会员才能听。")
        default:
            throw NeteaseError.noPlayableURL("网易没给地址（代码 \(code)），可能 Cookie 过期了。")
        }
    }

    func lyric(for id: String) async throws -> String {
        let json = try await post(
            path: "/weapi/song/lyric",
            params: ["id": id, "lv": -1, "kv": -1, "tv": -1]
        )
        if let lrc = json["lrc"] as? [String: Any], let text = lrc["lyric"] as? String {
            return text
        }
        return ""
    }

    // MARK: - 底层请求

    private func post(path: String, params: [String: Any]) async throws -> [String: Any] {
        guard var components = URLComponents(string: base + path) else {
            throw NeteaseError.badResponse("路径拼错了")
        }
        components.queryItems = [URLQueryItem(name: "csrf_token", value: "")]

        guard let url = components.url,
              let encrypted = NeteaseCrypto.weapi(params: params) else {
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

        var body = "params=\(Self.encode(encrypted["params"] ?? ""))"
        body += "&encSecKey=\(Self.encode(encrypted["encSecKey"] ?? ""))"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NeteaseError.badResponse("HTTP 状态不对")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NeteaseError.badResponse(String(decoding: data.prefix(120), as: UTF8.self))
        }

        if let code = json["code"] as? Int, code != 200 {
            throw NeteaseError.api(code: code, message: (json["message"] as? String) ?? "")
        }
        return json
    }

    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: - 解析

    private static func track(fromSearchItem item: [String: Any]) -> MusicTrack? {
        guard let id = idString(item["id"]) else { return nil }
        let artists = (item["ar"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let album = (item["al"] as? [String: Any])?["name"] as? String ?? ""
        return MusicTrack(
            id: id,
            title: (item["name"] as? String) ?? "未命名",
            artist: artists.joined(separator: " / "),
            album: album,
            duration: ((item["dt"] as? Double) ?? 0) / 1000.0,
            url: nil
        )
    }

    private static func track(fromSongItem item: [String: Any]) -> MusicTrack? {
        guard let id = idString(item["id"]) else { return nil }
        // 老接口用 artists/album，新接口用 ar/al，两种都认
        let artists = (item["ar"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            ?? (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            ?? []
        let album = (item["al"] as? [String: Any])?["name"] as? String
            ?? (item["album"] as? [String: Any])?["name"] as? String
            ?? ""
        let duration = (item["dt"] as? Double) ?? (item["duration"] as? Double) ?? 0
        return MusicTrack(
            id: id,
            title: (item["name"] as? String) ?? "未命名",
            artist: artists.joined(separator: " / "),
            album: album,
            duration: duration / 1000.0,
            url: nil
        )
    }

    private static func idString(_ value: Any?) -> String? {
        if let number = value as? Int { return String(number) }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }
}
