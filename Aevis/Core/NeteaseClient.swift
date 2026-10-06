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

/// 一个歌单（列表用的轻量版 —— **不带曲目**，点进去才现拉）。
///
/// 为什么不复用 `MusicTrack` 那套：歌单和曲目是两个东西，硬塞进一个结构体
/// 会让"这个字段对歌单有没有意义"永远说不清。
struct NeteasePlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    var trackCount: Int
    var coverURL: URL?
    /// 网易的 `specialType`：**5 = 「我喜欢的音乐」**，20 = 年度歌单，0 = 普通歌单。
    /// 这个字段是"我喜欢的那张歌单"的**唯一**识别方式 —— 它的名字会跟着
    /// 账号语言变（「我喜欢的音乐」/「我喜欢的歌曲」），按名字找迟早会崩。
    var specialType: Int
    /// 这个歌单是我自己建的吗（`creator.userId == 我`）。
    var isMine: Bool
    /// 我收藏的别人的歌单。
    var isSubscribed: Bool

    var isLiked: Bool { specialType == 5 }
}

/// 当前登录的账号。
struct NeteaseAccount {
    var uid: String
    var nickname: String
    var avatarURL: URL?
}

/// 网易云里那张「人设自己的歌单」的**真名**。
///
/// ## 为什么要有这么一个名字（用户 2026-10-02 点名的做法）
/// 用户原话：「原理是在你的网易云添加一个歌单是属于他的，但是在这个，
/// 就是一整个我们的 App 里面，这个歌单显示的是 AI 的账号和他的歌单」。
///
/// 翻成实现就是：**歌单真的建在你自己的网易云账号里**（所以你打开网易云
/// 就能看到它、能自己往里加歌），但 App 界面上那一行显示成「ta的歌单」（见 `displayName`）——
/// 不显示这个真名。两边用的是同一份数据，只是叫法不同。
///
/// ⚠️ 名字里带**人设的名字**（「零砚的歌单」），所以**换人设之后就是另一个歌单** ——
///    这是有意的：歌单是"ta的"，不是"这台手机的"。
enum HerPlaylist {
    /// 找不到人设名的时候用的兜底。
    ///
    /// ⚠️ 这是**匹配键**，不是文案。老用户账号里已经有一个叫「她的歌单」的歌单，
    ///    改这里会导致找不到它。界面显示请走 `displayName`。
    static let fallback = "她的歌单"

    /// 在网易云里真实的歌单名。
    ///
    /// ⚠️ 这是**匹配键**，不是文案。老用户账号里已经有一个叫「她的歌单」的歌单，
    ///    改这里会导致找不到它。界面显示请走 `displayName`。
    static func realName(for persona: Persona) -> String {
        let her = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (her.isEmpty ? "她" : her) + "的歌单"
    }

    /// App 界面上显示的名字。
    ///
    /// ⭐ 这一层**跟随人设性别**（走 `Pronoun`）—— 而 `realName` 是匹配键、**不跟着变**。
    /// 两者故意分开：改显示不会动到网易云里的真名。
    /// （以前它直接返回 `realName`，所以「不设定 / 无性别」时会显示那个兜底名。）
    static func displayName(for persona: Persona) -> String {
        let her = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if her.isEmpty {
            return Pronoun.spaced(persona.pronoun) + "的歌单"
        }
        return her + "的歌单"
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
            case -2:
                // 探针实测：这个码就是「无权限访问」。401/301 之外最常见的一个。
                return "网易说没权限访问（code -2）。这一般是 Cookie 过期了 —— "
                    + "去「音乐」页重新登录一次就好。"
            case 462:
                // 写接口（建歌单 / 加歌）最容易撞上它：网页端也要过一道验证码。
                return "网易的写接口被风控拦了（code 462）。这个接口在网页上也要过验证，"
                    + "先去网易云网页版随便操作一下、过一会儿再试。"
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

    // MARK: - 我的音乐（喜欢 / 最近 / 歌单）
    //
    // 用户 2026-10-02 要的：「他的喜欢、历史歌单、和他添加的歌单都加上」。
    //
    // ⚠️ 这一整段的接口**都是探针实测过存在的**（`_verify/_probe_netease_endpoints.py`）：
    //    未登录时 `/api/user/playlist` 照样能被别人账号的公开歌单列表拿回来
    //    （`specialType` 5 = 我喜欢的音乐 就在里面），`/api/v1/play/record` 则回
    //    `code -2 无权限访问` —— 说明路径和参数名都对，只差一个 Cookie。

    /// uid 在 UserDefaults 里的缓存键。uid 一辈子不会变，不值得每次现问。
    private static let uidDefaultsKey = "aevis.netease.uid"

    /// 我现在是谁。
    ///
    /// ⚠️ 未登录时网易返回的是 `{"code":200,"account":null,"profile":null}` ——
    ///    **code 是 200、但内容全空**。所以不能只看 code，要盯着 `profile` 有没有。
    ///    这个形状是探针实测的，别改成"看 code 是不是 200"。
    func account() async throws -> NeteaseAccount {
        guard isLoggedIn else {
            throw NeteaseError.api(code: 301, message: "还没登录")
        }
        let json = try await plainRequest("/api/nuser/account/get", [:])
        guard let profile = json["profile"] as? [String: Any],
              let uid = Self.idString(profile["userId"]) else {
            throw NeteaseError.badResponse(
                "没拿到账号信息（\(Self.brief(json))）。Cookie 多半过期了，去「音乐」页重新登录一下。")
        }
        let nickname = (profile["nickname"] as? String) ?? ""
        UserDefaults.standard.set(uid, forKey: Self.uidDefaultsKey)
        return NeteaseAccount(
            uid: uid,
            nickname: nickname,
            avatarURL: (profile["avatarUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    /// 当前账号的 uid。有缓存就用缓存，没有现问一次。
    ///
    /// 缓存不只是省一次请求：**「我的歌单 / 最近播放」这些接口全都要 uid**，
    /// 每次现问一遍等于每个功能都多一次往返，而且网易那边 uid 是敏感信息。
    func uid(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh,
           let cached = UserDefaults.standard.string(forKey: Self.uidDefaultsKey),
           !cached.isEmpty {
            return cached
        }
        return try await account().uid
    }

    /// 我建的 + 我收藏的歌单。**「我喜欢的音乐」也在这张表里**（`specialType == 5`）。
    ///
    /// 网易的 `limit` 有时会被忽略（探针里给 5 却回了 6 条），所以这里按
    /// 「`more` 是不是 true」翻页，并且最多翻两轮 —— 几百个歌单的账号极罕见，
    /// 万一真遇到也宁可少列几个，不要把一个页面卡在加载上。
    func myPlaylists(uid: String) async throws -> [NeteasePlaylist] {
        var collected: [NeteasePlaylist] = []
        var offset = 0

        for _ in 0..<2 {
            let json = try await plainRequest("/api/user/playlist", [
                "uid": uid, "limit": "1000", "offset": "\(offset)"
            ])
            let items = (json["playlist"] as? [[String: Any]]) ?? []
            collected.append(contentsOf: items.compactMap { Self.playlist(from: $0, uid: uid) })
            guard (json["more"] as? Bool) == true, !items.isEmpty else { break }
            offset += items.count
        }

        // 同一个歌单可能被翻页带回来两次 —— 按 id 去重，省得界面上出现两行一样的。
        var seen = Set<String>()
        return collected.filter { seen.insert($0.id).inserted }
    }

    /// 我的全部歌单（自己解析 uid）。
    func myPlaylists() async throws -> [NeteasePlaylist] {
        try await myPlaylists(uid: try await uid())
    }

    /// 「我喜欢的音乐」那张歌单。找不到就是 nil。
    func likedPlaylist() async throws -> NeteasePlaylist? {
        try await myPlaylists().first { $0.isLiked }
    }

    /// 我喜欢的歌。
    func likedTracks() async throws -> [MusicTrack] {
        guard let liked = try await likedPlaylist() else {
            throw NeteaseError.badResponse(
                "没找到「我喜欢的音乐」这张歌单 —— 可能是还没红心过任何歌。")
        }
        return try await playlistDetail(liked.id)
    }

    /// 最近播放。
    ///
    /// ⚠️ 这个接口**未登录会被直接拒**（探针实测 `code -2`），和搜索不一样 ——
    ///    搜索未登录也能用，所以别拿"搜索通"当成"登录有效"的证据。
    ///
    /// 返回里 `allData` 是全部记录、`weekData` 是最近一周；有 allData 就用它，
    /// 没有才退回 weekData（新账号 / 刚清过记录时会只有一份）。
    func recentTracks(limit: Int = 100) async throws -> [MusicTrack] {
        let uid = try await uid()
        let json = try await plainRequest("/api/v1/play/record", ["uid": uid, "type": "1"])

        let all = (json["allData"] as? [[String: Any]]) ?? []
        let week = (json["weekData"] as? [[String: Any]]) ?? []
        let rows = all.isEmpty ? week : all

        // 每条是 `{"song": {...}, "playCount": n}` —— 要的是里面那个 song。
        let songs = rows.compactMap { $0["song"] as? [String: Any] }.prefix(limit)
        guard !songs.isEmpty else {
            throw NeteaseError.badResponse("最近播放是空的（\(Self.brief(json))）")
        }
        return await attachCovers(to: Self.dedupe(songs.compactMap(Self.track(from:))))
    }

    /// 按 id **精确**拿歌。
    ///
    /// 🔴 这个函数存在的唯一原因是修一个真 bug：`play_music` 拿到 `song_id` 之后
    ///    原来是**把 id 当关键词丢进搜索**的（`search("33894312")`）——
    ///    那当然搜不到东西。后果是"ta放了我喜欢的某一首"永远是一句空话：
    ///    模型从 `my_music` 里明明拿到了正确的 id，却怎么也放不出来。
    ///
    /// `/api/v3/song/detail` 本来就是"一次问多首"，所以顺手支持批量。
    /// 它返回的 `songs[].al.picUrl` 里**直接带封面**，不用再补一次。
    func tracks(ids: [String]) async throws -> [MusicTrack] {
        let clean = ids.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return [] }
        let payload = "[" + clean.map { "{\"id\":\($0)}" }.joined(separator: ",") + "]"

        let json = try await plainRequest("/api/v3/song/detail", ["c": payload])
        guard let songs = json["songs"] as? [[String: Any]] else {
            throw NeteaseError.badResponse("没拿到这首歌（\(Self.brief(json))）")
        }
        return songs.compactMap { item -> MusicTrack? in
            guard var track = Self.track(from: item) else { return nil }
            if let pic = (item["al"] as? [String: Any])?["picUrl"] as? String,
               !pic.isEmpty, let url = URL(string: pic) {
                track.coverURL = url
            }
            return track
        }
    }

    /// 按 id 拿一首。拿不到就是 nil（版权下架之类）。
    func track(id: String) async throws -> MusicTrack? {
        try await tracks(ids: [id]).first
    }

    /// 从返回体里解出一条歌单。
    ///
    /// ⚠️ `creator.userId` 和顶层的 `userId` 两个地方都可能承载"是谁的" ——
    ///    探针实测两个都有。优先用 `creator.userId`，取不到再退回顶层。
    private static func playlist(from item: [String: Any], uid: String) -> NeteasePlaylist? {
        guard let id = idString(item["id"]) else { return nil }
        let creatorUID = idString((item["creator"] as? [String: Any])?["userId"])
            ?? idString(item["userId"])
        return NeteasePlaylist(
            id: id,
            name: (item["name"] as? String) ?? "未命名歌单",
            trackCount: (item["trackCount"] as? Int) ?? 0,
            coverURL: (item["coverImgUrl"] as? String).flatMap(URL.init(string:)),
            specialType: (item["specialType"] as? Int) ?? 0,
            isMine: creatorUID == uid,
            isSubscribed: (item["subscribed"] as? Bool) ?? false
        )
    }

    // MARK: - 写：建歌单 / 加歌
    //
    // 🔴 **这是整个网易云接入里最脆的一段。**
    //
    // 读接口挂了最多是"看不到"，写接口挂了会让用户以为"ta收藏了"、
    // 其实什么都没写进去 —— 那是**假装完成**，是最不能忍的一类问题。
    // 所以这里每一个失败都原样把网易的 code/message 带出去，绝不吞。
    //
    // 探针实测（未登录）：
    //   · `/api/playlist/create`              → `code 301`（要登录）✅ 路径对
    //   · `/api/playlist/manipulate/tracks`   → `code 404 歌单不存在` ✅ 参数名 op/pid/trackIds 对

    /// 从 Cookie 里抠出 `__csrf`。
    ///
    /// 写接口必须带上它，而它**不在** `MUSIC_U` 里 —— 是同一份 Cookie 串里的另一条。
    /// `NeteaseLogin` 抓 Cookie 时是把 163 域名下的**全部** cookie 拼在一起的，
    /// 所以只要网页端有它，这里就有。取不到就返回空串（网易对此的反应是 301/462，
    /// 会被上面的错误话术照实说出来，不会静悄悄失败）。
    private var csrf: String {
        for piece in cookie.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("__csrf=") else { continue }
            return String(trimmed.dropFirst("__csrf=".count))
        }
        return ""
    }

    /// 表单编码成一个 POST body。
    ///
    /// ⚠️ **不要用 `Self.formEncode`** —— 那个是给 weapi 的 base64 用的白名单编码，
    ///    会把中文歌单名编成 `%E4%BD%A0...` 之外的怪东西。这里走 `queryItems`
    ///    交给 Foundation 编（和 `plainRequest` 同一条路），中文、方括号全都不用管。
    private static func formBody(_ form: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = form
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }

    /// 明文 POST（表单）。写接口只能走这条 —— 那几个 GET 的都是只读的。
    private func plainPost(_ path: String, _ form: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else {
            throw NeteaseError.badResponse("路径拼错了：\(path)")
        }
        guard isLoggedIn else {
            throw NeteaseError.api(code: 301, message: "还没登录")
        }

        var payload = form
        payload["csrf_token"] = csrf

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(base + "/", forHTTPHeaderField: "Referer")
        request.setValue(base, forHTTPHeaderField: "Origin")
        if !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = Data(Self.formBody(payload).utf8)

        return try await send(request, label: "写 \(path)")
    }

    /// 建一个歌单，返回新歌单的 id。
    func createPlaylist(name: String) async throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw NeteaseError.badResponse("歌单名不能是空的。")
        }
        let json = try await plainPost("/api/playlist/create", ["name": clean])
        // 新老返回体不一样：老版顶层给 id，新版包在 playlist 里。两个都认。
        if let id = Self.idString(json["id"]) { return id }
        if let nested = json["playlist"] as? [String: Any], let id = Self.idString(nested["id"]) {
            return id
        }
        throw NeteaseError.badResponse("建歌单没返回 id（\(Self.brief(json))）")
    }

    /// 把一批歌加进一个歌单。
    ///
    /// `trackIds` 是**纯 id 的 JSON 数组**（`[123,456]`）—— 别照抄旁边
    /// `attachCovers` 那个 `[{"id":123}]`：那是 `/api/v3/song/detail` 的格式，
    /// 两个接口要的东西不一样。
    func addTracks(_ ids: [String], to playlistID: String) async throws {
        let clean = ids.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        let payload = "[" + clean.joined(separator: ",") + "]"
        _ = try await plainPost("/api/playlist/manipulate/tracks", [
            "op": "add", "pid": playlistID, "trackIds": payload
        ])
    }

    /// ta的歌单：**先在你账号里按名字找**，找不到才建。
    ///
    /// ⚠️ 为什么不把 pid 存下来：歌单随时会被你自己删掉或改名，
    ///    存一个 id 就等于埋一个"以后必然失效"的值。每次现找一遍，
    ///    删了ta那边下次收藏时自然就重建 —— 比缓存稳。
    func ensureHerPlaylist(named name: String) async throws -> String {
        let mine = try await myPlaylists()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = mine.first(where: { $0.name == clean }) {
            return hit.id
        }
        return try await createPlaylist(name: clean)
    }

    /// 把一首歌收进ta的歌单（没有就先建）。返回歌单 id。
    @discardableResult
    func saveToHerPlaylist(songID: String, playlistName: String) async throws -> String {
        let pid = try await ensureHerPlaylist(named: playlistName)
        try await addTracks([songID], to: pid)
        return pid
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
