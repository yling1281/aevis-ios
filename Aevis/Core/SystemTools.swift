import Foundation

/// 她与系统之间的几只新手：打开链接、跑快捷指令、回主界面、看屏幕、解析抖音、锁屏。
///
/// 这里每一只都**真会做事**；App 自己做不到的（比如锁屏），
/// 就走「跑一个快捷指令」这条绕路，而不是假装失败。
extension DeviceTools {

    static var systemTools: [DeviceTool] {
        [openLinkTool, runShortcutTool, goHomeTool, lookAtScreenTool,
         douyinLinkTool, lockScreenTool, screenTimeTool]
    }

    // MARK: - 锁屏

    private static var lockScreenTool: DeviceTool {
        DeviceTool(
            name: "lock_screen",
            title: "帮你锁了屏",
            description: """
            锁屏。App 自己做不到，所以实际是**跑用户做好的「锁屏」快捷指令**
            （会跳到快捷指令 App 执行一下，屏幕就锁了）。
            对方说「锁屏」「我要睡了」时用它。
            用户还没做好那个快捷指令时会失败 —— 如实告诉他怎么弄。
            """,
            parameters: emptyParameters()
        ) { _ in
            ShortcutBridge.lockScreenViaShortcut()
        }
    }

    // MARK: - 屏幕使用时间

    private static var screenTimeTool: DeviceTool {
        DeviceTool(
            name: "get_screen_time",
            title: "看了下你的屏幕使用时间",
            description: """
            看对方今天的屏幕使用时间。数据是**快捷指令跑完发回来的**
            （App 自己取不到，那个权限这张签名里没有）。
            对方问「我今天刷了多久手机」时用它。
            没有数据就如实说还没有，并告诉他怎么做一个快捷指令把数据发过来。
            """,
            parameters: emptyParameters()
        ) { _ in
            let insight = ScreenTimeInsight.shared
            guard insight.hasData else {
                return """
                还没有屏幕使用时间的数据。
                这个数据 App 自己取不到，需要对方在「快捷指令」里做一个流程，
                最后加一步「打开 URL」填：
                aevis://screentime?minutes=总分钟数&top=用得最多的几个App
                """
            }
            return insight.digest()
        }
    }

    // MARK: - 打开链接 / App

    private static var openLinkTool: DeviceTool {
        DeviceTool(
            name: "open_link",
            title: "打开了个链接",
            description: """
            在手机上打开一个链接或 App。可以传网页地址（https://...），
            也可以传 App 的 scheme，比如抖音是 snssdk1128://、微信是 weixin://。
            对方说「打开这个」「帮我点开」时用它。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "要打开的链接或 scheme"]
                ],
                "required": ["url"]
            ]
        ) { args in
            guard let text = args["url"] as? String, !text.isEmpty else {
                return "没给要打开的链接。"
            }
            // 抖音单独走一下：装的是 App 就开 App，没装就退网页
            if text.contains("douyin.com") || text.lowercased().hasPrefix("snssdk") {
                return ShortcutBridge.openDouyin() ? "打开了抖音。" : "打不开抖音 —— 可能没装。"
            }
            return ShortcutBridge.open(text) ? "打开了：\(text)" : "打不开这个链接。"
        }
    }

    // MARK: - 快捷指令

    private static var runShortcutTool: DeviceTool {
        DeviceTool(
            name: "run_shortcut",
            title: "跑了个快捷指令",
            description: """
            运行用户手机里已经做好的一个「快捷指令」。传的是**指令的名字**，不是内容。
            适合做那些 App 自己做不到的事，比如锁屏、开某个 App、控制智能家居。
            没装快捷指令、或者名字不对时会失败，如实告诉用户。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "快捷指令的名字，要和用户做好的那个完全一致"]
                ],
                "required": ["name"]
            ]
        ) { args in
            guard let name = args["name"] as? String, !name.isEmpty else {
                return "没给快捷指令的名字。"
            }
            guard ShortcutBridge.isShortcutsAvailable else {
                return "这台设备上跑不了快捷指令。"
            }
            return ShortcutBridge.runShortcut(named: name)
                ? "跑了「\(name)」。"
                : "没跑起来 —— 检查一下有没有这个同名快捷指令。"
        }
    }

    // MARK: - 回主界面

    private static var goHomeTool: DeviceTool {
        DeviceTool(
            name: "go_home",
            title: "把你送回主界面",
            description: """
            把 App 收到后台，也就是**回到手机主屏幕**。
            对方说「回主界面」「关掉这个界面」时用它。
            注意：**只能回主界面，不能锁屏** —— iOS 不允许 App 锁屏，
            用户要锁屏得用快捷指令。
            """,
            parameters: emptyParameters()
        ) { _ in
            guard ShortcutBridge.canGoHome else {
                return "这台系统上回不了主界面（系统内部接口变了）。可以让用户自己上滑。"
            }
            return ShortcutBridge.goHome() ? "已经回主界面了。" : "回主界面失败。"
        }
    }

    // MARK: - 看屏幕

    private static var lookAtScreenTool: DeviceTool {
        DeviceTool(
            name: "look_at_screen",
            title: "看了眼你的屏幕",
            description: """
            看用户屏幕上**最近认出来的文字**（这是录屏陪伴攒下来的）。
            对方问「你看到我在干嘛吗」时用它。
            注意：只有对方打开了「录屏陪伴」才有内容；
            而且屏幕上如果是图片或视频、没有文字，你也看不到。
            """,
            parameters: emptyParameters()
        ) { _ in
            let companion = ScreenCompanion.shared
            guard companion.active else {
                return "对方没开录屏陪伴，我看不到他的屏幕。"
            }
            guard !companion.lastSeen.isEmpty else {
                return "开着，但我还没看到有文字的内容。"
            }
            let recent = companion.observations.prefix(3)
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            return "他屏幕上最近的文字：\n\(recent)"
        }
    }

    // MARK: - 抖音链接

    private static var douyinLinkTool: DeviceTool {
        DeviceTool(
            name: "parse_douyin_link",
            title: "解析了个抖音链接",
            description: """
            从一段抖音分享文案里把链接抠出来，并读出这条作品是什么
            （标题、作者、作品 ID）。
            对方粘过来一段「复制打开抖音…」的时候用它 ——
            这样你能说出来那是什么内容，而不是复述一串乱码。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "用户粘过来的那段分享文案，含链接"]
                ],
                "required": ["text"]
            ]
        ) { args in
            guard let text = args["text"] as? String, !text.isEmpty else {
                return "没给要解析的内容。"
            }
            do {
                let share = try await DouyinClient.shared.resolve(text)
                var lines = ["解析出来了："]
                if !share.author.isEmpty { lines.append("作者：\(share.author)") }
                if !share.title.isEmpty { lines.append("标题：\(share.title)") }
                if !share.videoID.isEmpty { lines.append("作品 ID：\(share.videoID)") }
                lines.append("链接：\(share.link)")
                return lines.joined(separator: "\n")
            } catch {
                return error.localizedDescription
            }
        }
    }
}
