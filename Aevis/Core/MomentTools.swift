import Foundation

/// 她在朋友圈里的两只手：发一条、看别人发了什么。
///
/// **重要**：`post_moment` 的描述里明确要求「必须真的调用」——
/// 用户说过「说了要发就必须真发」，所以不能让她只回一句「好，我发啦」然后什么都没发生。
extension DeviceTools {

    static var momentTools: [DeviceTool] {
        [postMomentTool, readMomentsTool]
    }

    // MARK: - 发一条

    private static var postMomentTool: DeviceTool {
        DeviceTool(
            name: "post_moment",
            title: "发了条朋友圈",
            description: """
            在朋友圈里发一条动态，署名是你自己。
            对方说「你发个朋友圈」「发条动态」时，**必须真的调用这个工具**，
            不要只是回一句「好的我发了」——那样什么都没发生。
            内容按你自己的性格写，一两句话，不要话题标签，不要引号。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "要发的内容，一两句话"]
                ],
                "required": ["text"]
            ]
        ) { args in
            guard let text = args["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "没给要发的内容。"
            }
            guard let moment = MomentStore.shared.post(text: text, author: .ta) else {
                return "发失败了。"
            }
            return "发出去了：\(moment.text)"
        }
    }

    // MARK: - 看朋友圈

    private static var readMomentsTool: DeviceTool {
        DeviceTool(
            name: "read_moments",
            title: "刷了下朋友圈",
            description: """
            看朋友圈里最近有什么动态（对方发的和你自己发的都在里面）。
            对方让你评价、或者提到朋友圈里的某件事时用它，别凭印象编。
            参数 count 表示看几条，默认 6。
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "count": ["type": "integer", "description": "看几条，1~20，默认 6"]
                ],
                "required": [] as [String]
            ]
        ) { args in
            let count = min(max((args["count"] as? Int) ?? 6, 1), 20)
            let digest = MomentStore.shared.digest(limit: count)
            guard !digest.isEmpty else {
                return "朋友圈还是空的，谁都没发。"
            }
            return "最近的朋友圈：\n\(digest)"
        }
    }
}
