import Foundation

/// 音乐相关的手：找歌、放歌、控制播放、读当前歌词。
///
/// 有了这几个，「一起听」才成立 —— 她能知道现在放到哪一句，
/// 才能就着歌词跟你说话，而不是只会"正在播放"。
extension DeviceTools {

    static var musicTools: [DeviceTool] {
        [searchMusicTool, playMusicTool, musicControlTool, currentLyricTool]
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
                return "还没登录网易云，我搜不了。让用户去「设置 → 音乐」把 Cookie 贴进来。"
            }
            let limit = min(max((args["limit"] as? Int) ?? 8, 1), 20)
            do {
                let tracks = try await NeteaseClient.shared.search(keyword, limit: limit)
                guard !tracks.isEmpty else { return "没搜到「\(keyword)」。" }
                let lines = tracks.enumerated().map { index, track in
                    "\(index + 1). \(track.display)（id \(track.id)）"
                }
                return "搜到这些：\n" + lines.joined(separator: "\n")
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
            让她真的开始放歌。给 keyword 就搜第一首放，给 song_id 就放指定那首。
            用户说「放首歌」「我想听某某」时用它 —— **必须真的调用它**，
            不要只是回一句「好的我放给你听」。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "keyword": ["type": "string", "description": "歌名或歌手，放搜到的第一首"],
                    "song_id": ["type": "string", "description": "已知歌曲 id 时直接给"]
                ],
                "required": [] as [String]
            ]
        ) { args in
            guard NeteaseClient.shared.isLoggedIn else {
                return "还没登录网易云，放不了。让用户去「设置 → 音乐」把 Cookie 贴进来。"
            }

            var track: MusicTrack?
            do {
                if let id = args["song_id"] as? String, !id.isEmpty {
                    let tracks = try await NeteaseClient.shared.search(id, limit: 1)
                    track = tracks.first
                } else if let keyword = args["keyword"] as? String, !keyword.isEmpty {
                    let tracks = try await NeteaseClient.shared.search(keyword, limit: 1)
                    track = tracks.first
                }
            } catch {
                return "找歌失败：\(error.localizedDescription)"
            }

            guard let picked = track else {
                return "没找到要放的那首歌。换个说法再试，或者先把歌名告诉我。"
            }

            await MusicPlayer.shared.play([picked])
            if let message = MusicPlayer.shared.errorText {
                return "找到了《\(picked.title)》，但放不出来：\(message)"
            }
            return "开始放了：《\(picked.display)》"
        }
    }

    private static var musicControlTool: DeviceTool {
        DeviceTool(
            name: "music_control",
            title: "动了下播放器",
            description: "控制音乐：暂停 / 继续 / 下一首 / 上一首 / 停止。用户说「停一下」「换一首」时用它。",
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "description": "pause / resume / next / previous / stop"
                    ]
                ],
                "required": ["action"]
            ]
        ) { args in
            guard let action = (args["action"] as? String)?.lowercased() else {
                return "没给要做什么。"
            }
            let player = MusicPlayer.shared
            switch action {
            case "pause":
                player.pause()
                return "暂停了。"
            case "resume":
                player.resume()
                return "继续放了。"
            case "next":
                await player.next()
                return player.current.map { "换成了《\($0.display)》" } ?? "队列是空的。"
            case "previous":
                await player.previous()
                return player.current.map { "回到《\($0.display)》" } ?? "队列是空的。"
            case "stop":
                player.stop()
                return "停了。"
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
            let player = MusicPlayer.shared
            guard let track = player.current else {
                return "现在没有在放歌。"
            }
            let line = player.currentLyricLine ?? "（还没到有歌词的地方，或者这首歌没有歌词）"
            return """
            正在放：\(track.display)
            进度：\(Int(player.progress)) / \(Int(player.duration)) 秒
            当前这一句：\(line)
            """
        }
    }
}
