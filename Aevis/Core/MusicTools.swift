import Foundation

/// 音乐相关的手：找歌、放歌、控制播放、读当前歌词、
/// 看用户的音乐库（喜欢 / 最近 / 歌单）、把歌收进她的歌单。
///
/// 有了这几个，「一起听」才成立 —— 她能知道现在放到哪一句，
/// 才能就着歌词跟你说话，而不是只会"正在播放"。
///
/// 用户 2026-10-02 把权限这条点名说清楚了：
/// 「给 AI 的权限就是你可以让他切歌……可以让他暂停……有他喜欢的也可以」。
/// 所以这一版补了三样、修了一处真假完成：
///   1. `music_control` 多了 `seek`（跳着听）
///   2. 新增 `my_music` —— 她能看见**你喜欢什么、最近在听什么、有哪些歌单**
///   3. 新增 `save_to_her_playlist` —— 她能把歌收进「她的歌单」
///   4. `play_music` 的 `song_id` 以前是当关键词搜的，**根本放不出来**，已修
extension DeviceTools {

    static var musicTools: [DeviceTool] {
        [
            searchMusicTool, playMusicTool, musicControlTool, currentLyricTool,
            myMusicTool, saveToHerPlaylistTool
        ]
    }

    private static var searchMusicTool: DeviceTool {
        DeviceTool(
            name: "search_music",
            title: "翻了翻网易云",
            description: """
            在网易云音乐里搜歌，返回歌名、歌手和歌曲 id。
            用户说「找首歌」「放一下某首歌」但还没确定是哪一首时先搜。
            需要用户先在「音乐」里登录（贴 Cookie），没登录会返回提示。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "keyword": ["type": "string", "description": "歌名或歌手"],
                    "limit": ["type": "integer", "description": "要几条，默认 8"]
                ],
                "required": ["keyword"]
            ]
        ) { args in
            guard let keyword = args["keyword"] as? String, !keyword.isEmpty else {
                return "没给搜索关键词。"
            }
            guard NeteaseClient.shared.isLoggedIn else {
                return "还没登录网易云，我搜不了。让用户去「设置 → 音乐」登录一次。"
            }
            let limit = min(max((args["limit"] as? Int) ?? 8, 1), 20)
            do {
                let tracks = try await NeteaseClient.shared.search(keyword, limit: limit)
                guard !tracks.isEmpty else { return "没搜到「\(keyword)」。" }
                return "搜到这些：\n" + trackLines(tracks, limit: limit)
            } catch {
                return "搜不了：\(error.localizedDescription)"
            }
        }
    }

    private static var playMusicTool: DeviceTool {
        DeviceTool(
            name: "play_music",
            title: "放起了音乐",
            description: """
            让她真的开始放歌。
            · 给 keyword → 搜第一首放
            · 给 song_id → 精确放那一首
            · 给 source → 把**整个列表**当成播放队列放，这样之后「下一首 / 上一首」才有歌可换：
              liked = 我喜欢的，recent = 最近播放，playlist:<歌单id> = 某个歌单
            用户说「放首歌」「我想听某某」「放我喜欢的」时用它 —— **必须真的调用它**，
            不要只是回一句「好的我放给你听」。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "keyword": ["type": "string", "description": "歌名或歌手，放搜到的第一首"],
                    "song_id": ["type": "string", "description": "已知歌曲 id 时直接给"],
                    "source": [
                        "type": "string",
                        "description": "整张列表当队列：liked / recent / playlist:<歌单id>"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            guard NeteaseClient.shared.isLoggedIn else {
                return "还没登录网易云，放不了。让用户去「设置 → 音乐」登录一次。"
            }

            // ---- 情形一：从一整张列表开始放（把整张列表变成播放队列）----
            //
            // ⚠️ 这条路是「让 AI 切歌」能不能成立的关键：
            //    以前不管放什么，队列里永远只有**一首**（`play([picked])`），
            //    所以「下一首」按下去什么都不会发生 —— 她嘴上说"给你换一首"，
            //    实际是空转。整张列表进队列之后 next/previous 才真的有意义。
            if let raw = (args["source"] as? String)?.trimmingCharacters(in: .whitespaces),
               !raw.isEmpty {
                let source = raw.lowercased()
                var fetched: [MusicTrack] = []
                var label = "那个歌单"
                do {
                    if source == "liked" {
                        fetched = try await NeteaseClient.shared.likedTracks()
                        label = "我喜欢的音乐"
                    } else if source == "recent" {
                        fetched = try await NeteaseClient.shared.recentTracks(limit: 100)
                        label = "最近播放"
                    } else {
                        let pid = source.hasPrefix("playlist:")
                            ? String(source.dropFirst("playlist:".count))
                            : source
                        fetched = try await NeteaseClient.shared.playlistDetail(pid)
                    }
                } catch {
                    return "拿不到这个列表：\(error.localizedDescription)"
                }
                guard !fetched.isEmpty else { return "「\(label)」里一首歌都没有。" }

                var index = 0
                if let wantID = args["song_id"] as? String,
                   let hit = fetched.firstIndex(where: { $0.id == wantID }) {
                    index = hit
                }
                let first = fetched[index]

                await MainActor.run {
                    _ = Task { await MusicPlayer.shared.play(queue: fetched, index: index) }
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                if let message = await MainActor.run(body: { MusicPlayer.shared.errorText }) {
                    return "从《\(first.title)》开始放，但放不出来：\(message)"
                }
                return "开始放「\(label)」，一共 \(fetched.count) 首，现在这首是《\(first.display)》"
                    + " —— 后面想换就跟我说。"
            }

            // ---- 情形二：单曲 ----
            var track: MusicTrack?
            do {
                if let id = (args["song_id"] as? String)?.trimmingCharacters(in: .whitespaces),
                   !id.isEmpty {
                    // 🔴 这里原来写的是 `search(id, limit: 1)` —— 把一串**数字当关键词去搜**，
                    //    永远搜不到东西。后果很具体：模型从 `my_music` 里拿到了正确的
                    //    song_id，却怎么也放不出来，于是"她放了我收藏的那首"成了空话。
                    track = try await NeteaseClient.shared.track(id: id)
                } else if let keyword = args["keyword"] as? String, !keyword.isEmpty {
                    track = try await NeteaseClient.shared.search(keyword, limit: 1).first
                }
            } catch {
                return "找歌失败：\(error.localizedDescription)"
            }

            guard let picked = track else {
                return "没找到要放的那首歌。换个说法再试，或者先把歌名告诉我。"
            }

            // 播放同样要跳回主线程（理由见 `music_control` 那段说明）。
            // 给它一点时间把播放地址取回来，这样「放不出来」能当场说清楚。
            await MainActor.run { _ = Task { await MusicPlayer.shared.play([picked]) } }
            try? await Task.sleep(nanoseconds: 900_000_000)
            // ⚠️ `errorText` 是 `@MainActor` 的 `@Published` —— 读它也得跳回去。
            if let message = await MainActor.run(body: { MusicPlayer.shared.errorText }) {
                return "找到了《\(picked.title)》，但放不出来：\(message)"
            }
            return "开始放了：《\(picked.display)》"
        }
    }

    private static var musicControlTool: DeviceTool {
        DeviceTool(
            name: "music_control",
            title: "动了下播放器",
            description: """
            控制音乐：暂停 / 继续 / 下一首 / 上一首 / 停止 / 跳到某一段。
            用户说「停一下」「换一首」「回到刚才那段」时用它。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "pause / resume / next / previous / stop / seek"
                    ],
                    "seconds": [
                        "type": "number",
                        "description": "只有 action=seek 时用。正数是跳到第几秒；"
                            + "负数是**从当前位置往回**退多少秒（-15 = 退回 15 秒重听）"
                    ]
                ],
                "required": ["action"]
            ]
        ) { args in
            guard let action = (args["action"] as? String)?.lowercased() else {
                return "没给要做什么。"
            }
            // ⚠️ 每个动作都必须**跳回主线程**再动播放器。
            // 这些工具是在 `LLMService` 的 `Task.detached` 里跑的（**不在主线程**），
            // 而 `MusicPlayer` 现在是 `@MainActor` 的 —— 碰它一点都得跳回去。
            // ⚠️ 连 `MusicPlayer.shared` 这句本身也要放在 `MainActor.run` 里面，
            //    在外面先取一个 `let player` 的话，Swift 会警告
            //    「main actor-isolated static property 'shared' cannot be accessed
            //    from outside of the actor」（build-61 的日志里就有这条）。
            switch action {
            case "pause":
                await MainActor.run { MusicPlayer.shared.pause() }
                return "暂停了。"
            case "resume":
                await MainActor.run { MusicPlayer.shared.resume() }
                return "继续放了。"
            case "next":
                await MainActor.run { _ = Task { await MusicPlayer.shared.next() } }
                // 换歌要现取播放地址，给它一点时间再读结果
                try? await Task.sleep(nanoseconds: 350_000_000)
                return await MainActor.run {
                    MusicPlayer.shared.current.map { "换成了《\($0.display)》" } ?? "队列是空的。"
                }
            case "previous":
                await MainActor.run { _ = Task { await MusicPlayer.shared.previous() } }
                try? await Task.sleep(nanoseconds: 350_000_000)
                return await MainActor.run {
                    MusicPlayer.shared.current.map { "回到《\($0.display)》" } ?? "队列是空的。"
                }
            case "stop":
                await MainActor.run { MusicPlayer.shared.stop() }
                return "停了。"
            case "seek":
                let raw = args["seconds"]
                let want = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? 0
                let landed = await MainActor.run { () -> Double? in
                    let player = MusicPlayer.shared
                    guard player.current != nil else { return nil }
                    // 负数是"往回退"——「回到刚才那句」比"跳到第 83 秒"自然得多，
                    // 而模型很难自己算准那个绝对秒数。
                    let target = want >= 0 ? want : player.progress + want
                    let clamped = min(max(target, 0), max(player.duration - 1, 0))
                    player.seek(toSeconds: clamped)
                    return clamped
                }
                guard let landed else { return "现在没有在放歌。" }
                return String(format: "跳到 %.0f 秒了。", landed)
            default:
                return "不认识这个动作：\(action)"
            }
        }
    }

    private static var currentLyricTool: DeviceTool {
        DeviceTool(
            name: "current_lyric",
            title: "看了眼歌词",
            description: """
            读当前正在放的那首歌的歌词，以及现在唱到哪一句。
            用户问「这首歌唱到哪了」「这歌词什么意思」时用它 ——
            这也是「一起听」的依据：你可以就着现在这一句跟她聊。
            """,
            parameters: emptyParameters()
        ) { _ in
            // ⚠️ 整个读取都在 `MainActor.run` 里做 —— 这个闭包跑在 `Task.detached` 上，
            // 而 `MusicPlayer` 是 `@MainActor` 的。拼好整段再拿出来，
            // 免得一行一行读、一行一行跳（那样又慢又容易漏一处）。
            let info = await MainActor.run { () -> String? in
                let player = MusicPlayer.shared
                guard let track = player.current else { return nil }
                let line = player.currentLyricLine
                    ?? "（还没到有歌词的地方，或者这首歌没有歌词）"
                return """
                正在放：\(track.display)
                进度：\(Int(player.progress)) / \(Int(player.duration)) 秒
                当前这一句：\(line)
                """
            }
            return info ?? "现在没有在放歌。"
        }
    }

    // MARK: - 用户的音乐库（用户 2026-10-02 要的）

    private static var myMusicTool: DeviceTool {
        DeviceTool(
            name: "my_music",
            title: "翻了翻你的音乐",
            description: """
            看用户的网易云：他**喜欢**的歌（liked）、**最近在听**什么（recent）、
            他自己的**歌单**列表（playlists）。
            用户说「放一首我喜欢的」「放我最近常听的」「看看我的歌单」时先调它拿信息，
            拿到歌曲 id 之后再调 play_music。
            ⚠️ 想放**整张列表**（这样之后能一直切下一首）就直接给
            play_music 的 source 参数，不用一个 id 一个 id 地放。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "what": [
                        "type": "string",
                        "description": "liked = 我喜欢的 / recent = 最近播放 / playlists = 我的歌单列表"
                    ]
                ],
                "required": [] as [String]
            ]
        ) { args in
            guard NeteaseClient.shared.isLoggedIn else {
                return "还没登录网易云，我看不了。让用户去「设置 → 音乐」登录一次。"
            }
            let what = ((args["what"] as? String) ?? "liked")
                .trimmingCharacters(in: .whitespaces).lowercased()

            do {
                switch what {
                case "recent":
                    let tracks = try await NeteaseClient.shared.recentTracks(limit: 20)
                    return "他最近在听：\n" + trackLines(tracks)

                case "playlists":
                    let list = try await NeteaseClient.shared.myPlaylists()
                    guard !list.isEmpty else { return "他一个歌单都没有。" }
                    let lines = list.map { item -> String in
                        // 「我喜欢的音乐」不是他自己建的，是系统那张 —— 标出来，
                        // 不然模型会把它当成一个普通歌单去 playlist:<id> 放，结果一样，
                        // 但它就没法说出"这是我喜欢的音乐"这句话了。
                        let tag = item.isLiked ? "（我喜欢的音乐）"
                            : (item.isMine ? "" : "（收藏的）")
                        return "- \(item.name)\(tag)：\(item.trackCount) 首，id \(item.id)"
                    }
                    return "他的歌单：\n" + lines.joined(separator: "\n")

                default:
                    let tracks = try await NeteaseClient.shared.likedTracks()
                    return "他喜欢的歌：\n" + trackLines(tracks)
                }
            } catch {
                return "看不了：\(error.localizedDescription)"
            }
        }
    }

    /// 把一首歌收进「她的歌单」。
    ///
    /// ## 这个歌单在哪儿（用户点名的做法，别改成"App 内部自嗨"）
    /// 它**真的建在用户自己的网易云账号里**，名字是「<她的名字>的歌单」。
    /// 用户原话：「原理是在你的网易云添加一个歌单是属于他的，但是在这个……
    /// App 里面，这个歌单显示的是 AI 的账号和他的歌单」。
    /// 所以：打开网易云能看见、能自己往里加歌；App 里那一条显示成「她的歌单」。
    private static var saveToHerPlaylistTool: DeviceTool {
        DeviceTool(
            name: "save_to_her_playlist",
            title: "收进了她的歌单",
            description: """
            把一首歌收进「她的歌单」（在用户自己的网易云账号里，没有就会自动建一个）。
            用户说「这首真好听，你收起来」「你收藏一下这首」时用它。
            ⚠️ 这是**写操作**，会真的改动用户的网易云 —— 只有他明确说要收藏时才用，
            别自己顺手收藏。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "song_id": ["type": "string", "description": "歌曲 id（可以先 search_music / my_music 拿到）"],
                    "keyword": ["type": "string", "description": "没有 id 时给歌名，会搜第一首"]
                ],
                "required": [] as [String]
            ]
        ) { args in
            guard NeteaseClient.shared.isLoggedIn else {
                return "还没登录网易云，收藏不了。让用户去「设置 → 音乐」登录一次。"
            }

            var songID = (args["song_id"] as? String)?.trimmingCharacters(in: .whitespaces)
            if songID?.isEmpty == true { songID = nil }

            if songID == nil, let keyword = args["keyword"] as? String, !keyword.isEmpty {
                do {
                    songID = try await NeteaseClient.shared.search(keyword, limit: 1).first?.id
                } catch {
                    return "找歌失败：\(error.localizedDescription)"
                }
            }
            guard let id = songID else {
                return "没说是哪一首。先给它 search_music 拿到 id，或者把歌名告诉我。"
            }

            // ⚠️ `PersonaStore` 不是 `@MainActor` 的，可以在工具这个 detached 上下文里读
            //    （`ProactiveService` / `QQBotService` 也是这么读的）。
            let persona = PersonaStore.shared.persona
            let realName = HerPlaylist.realName(for: persona)

            do {
                try await NeteaseClient.shared.saveToHerPlaylist(
                    songID: id, playlistName: realName)
                return "收进「\(HerPlaylist.displayName(for: persona))」了。"
            } catch {
                // 写接口是最容易失败的一段（风控 462 / Cookie 过期 301）——
                // 照实说清楚，**绝对不要**回一句"收藏好了"糊过去。
                return "没收藏成功：\(error.localizedDescription)"
            }
        }
    }

    /// 把一批歌拼成给模型看的一行行文字。
    ///
    /// 统一走这一个函数：`search_music` 原来自己拼了一份一模一样的，
    /// 结果"列表格式"有两个版本，模型偶尔会按错的格式去编 id。
    private static func trackLines(_ tracks: [MusicTrack], limit: Int = 12) -> String {
        guard !tracks.isEmpty else { return "（一首都没有）" }
        return tracks.prefix(limit).enumerated().map { index, track in
            "\(index + 1). \(track.display)（id \(track.id)）"
        }.joined(separator: "\n")
    }
}
