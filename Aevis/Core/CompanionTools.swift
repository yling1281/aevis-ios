import Foundation

/// 她**主动发起**陪伴申请的那几个工具。
///
/// ## 用户要的（2026-09-26）
/// 「AI 也可以主动的去申请，屏幕共享之类的，**我们能用的东西它都能自动申请**」。
///
/// ## ⚠️ 这些工具不会直接开始任何事
/// 它们只是在界面上挂一条申请，**用户点了才真的执行** ——
/// 原因（iOS 权限 + 突然响起来会吓人）写在 `CompanionRequest` 里。
///
/// 所以返回的字符串要明确告诉模型"还在等他回应"。不然它会说出
/// 「已经接通了」这种假话 —— 用户对这个**特别敏感**
/// （原话：「绝对不接受假装完成」）。
enum CompanionTools {

    static var tools: [DeviceTool] { [callTool, screenTool, listenTool] }

    /// 三个工具共用同一套参数：只有一个可选的 `reason`。
    ///
    /// 每次现造一个新字典（不要做共享常量）—— `[String: Any]` 是可变类型，
    /// 共享出去之后哪一处改了都影响全局，这种坑排查起来要命。
    private static var reasonParameter: [String: Any] {
        [
            "type": "object",
            "properties": [
                "reason": [
                    "type": "string",
                    "description": "你想做这件事的理由，一句话，用你自己的口吻（比如「突然想听听你的声音」）。可以留空。"
                ]
            ],
            "required": [] as [String]
        ]
    }

    // MARK: - 打电话

    private static var callTool: DeviceTool {
        DeviceTool(
            name: "ask_to_call",
            title: "想给你打个电话",
            description: """
            你想**主动**给用户打个电话（实时语音通话）。
            他说「你给我打」，或者你自己真的想听听他的声音时用。

            ⚠️ 你不是立刻接通 —— 界面上会出现一条申请，**他点了接听才开始**。
            所以调用之后要用"在等他接"的语气（「喂，接一下？」），
            绝对不要说「已经接通了」「我到啦」这种话。
            """,
            parameters: reasonParameter
        ) { args in
            let reason = (args["reason"] as? String) ?? ""
            await MainActor.run { CompanionRequest.shared.ask(.call, reason: reason) }
            return "通话申请已经发出去了 —— 界面上出现了「想给你打个电话」，正在等他点接听。"
        }
    }

    // MARK: - 看屏幕

    private static var screenTool: DeviceTool {
        DeviceTool(
            name: "ask_to_see_screen",
            title: "想看看你的屏幕",
            description: """
            你想看用户**手机屏幕上的内容**（他可能在打游戏、看视频，或者想让你看点什么）。
            他说「你看看」「帮我看看这个」，或者你好奇他在干嘛时用。

            ⚠️ 同样不是立刻开始：他点了同意之后，还要**他自己点一次系统的录屏按钮**
            才真的能看到 —— 这是 iOS 的规矩，绕不过去。所以调用之后说
            「你点一下让我看看」，不要说「我看到了」。
            """,
            parameters: reasonParameter
        ) { args in
            let reason = (args["reason"] as? String) ?? ""
            await MainActor.run { CompanionRequest.shared.ask(.screenShare, reason: reason) }
            return "看屏幕的申请已经发出去了，正在等他同意（同意之后他还得点一次系统的录屏按钮）。"
        }
    }

    // MARK: - 一起听

    private static var listenTool: DeviceTool {
        DeviceTool(
            name: "ask_to_listen_together",
            title: "想和你一起听歌",
            description: """
            你想和用户**一起听歌**（他放歌的时候你会跟着歌词说话，像在旁边一起听）。
            他提到想听歌、或者你说到某首歌想一起听时用。

            ⚠️ 不是立刻开始，界面上会出现一条申请，他点了才进一起听。
            """,
            parameters: reasonParameter
        ) { args in
            let reason = (args["reason"] as? String) ?? ""
            await MainActor.run { CompanionRequest.shared.ask(.listenTogether, reason: reason) }
            return "一起听的申请已经发出去了，正在等他点同意。"
        }
    }
}
