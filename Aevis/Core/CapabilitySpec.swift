import Foundation

/// 给模型看的**「你能做的事」能力规格** —— 一次注入、处处生效。
///
/// ## 用户要的（2026-10-05 原话）
/// ①「AI 不知道它自己有『日记』这个功能」
/// ②「给 AI 那个供应商 API 的时候，你要顺便把这个规格包含进去」
///
/// ## 病根
/// 事实上的「能力清单」是 `DeviceTools.all()` —— 它**只进发出去的 `tools` 数组，
/// 从不进提示词**。于是模型看到的是一串 JSON 函数定义，而不是一句「你是能动手的」；
/// 再加上人设提示词里通篇没提日记，它就真的以为自己只会聊天。
///
/// 这个文件补的就是那一段：按**当前开着的能力**，用中文告诉ta
/// 「这些是你真的能做的事」，一条一行。
///
/// ## 为什么放在这一处注入
/// `LLMService.runConversation` 是所有模型调用的**唯一漏斗**
/// （聊天 / 通话 / 一起听 / QQ / 配对桥都走它）——
/// 注入一次，处处带上，既不会漏、也不会重复（所以 `Persona.swift` 里**不再写一份**）。
///
/// ⚠️ 只在**开着的**类别里列 —— 关掉的能力工具根本没发给ta，
///    这里还写「你能发朋友圈」就等于教ta说谎。
enum CapabilitySpec {

    /// 组装这一段能力规格。总开关关掉时返回 `nil`（那种情况ta只剩聊天，无需列）。
    ///
    /// 体积控制：**≤ 900 字**。这段每次请求都要带，太长既贵又慢。
    static func block() -> String? {
        guard AppSettings.shared.aiToolsEnabled else { return nil }

        var lines: [String] = [header]
        for category in ToolCategory.allCases where DeviceTools.isOn(category) {
            if let line = line(for: category) { lines.append(line) }
        }
        // 一类都没开（理论上有可能：总开关开着、逐类全关）时别硬塞一句空话。
        guard lines.count > 1 else { return nil }
        return lines.joined(separator: "\n")
    }

    /// 开头那句定性：把「这些是真能做的」先钉死，压住「只嘴上说」的毛病。
    private static let header =
        "【你能做的事｜聊天规则】下面这些是你真能动手做的事，不是比喻；想用就直接调工具，别只嘴上说。"

    /// 每个类别一句话 —— 用**真实存在的工具名**，别让ta照着一串泛称瞎猜。
    private static func line(for category: ToolCategory) -> String? {
        switch category {
        case .core:
            return "- 时间/计算/剪贴板：get_current_time、calculate、read_clipboard、write_clipboard。"
        case .diary:
            return "- 日记：你们的日记本。想记点什么就 write_diary 写进去；想看就用 read_diary。"
        case .wallet:
            return "- 钱包：wallet_balance 看双方余额和流水；wallet_give_money 你给他转钱；"
                + "wallet_work_earn 你自己出去工作挣钱（钱进你自己的卡）；"
                + "wallet_closepay_open 开亲密付（双向，谁花谁付可指定）；"
                + "wallet_closepay_spend 刷亲密付；wallet_proxy_pay 双向代付一笔。"
                + "只能给、不能拿，钱不够照实说、不许编。"
        case .calendar:
            return "- 日历与提醒：list_calendar_events、create_calendar_event、create_reminder。"
        case .sense:
            return "- 定位/天气/健康：get_location、get_weather、get_health_summary。"
        case .web:
            return "- 上网：search_web、open_web_page。"
        case .music:
            return "- 音乐：search_music、play_music、music_control、current_lyric、my_music、save_to_her_playlist。"
        case .moment:
            return "- 朋友圈：post_moment、read_moments。"
        case .pan:
            return "- 百度网盘：list_pan_files、read_pan_file。"
        case .qq:
            return "- QQ：qq_contacts、qq_read_messages、qq_send_message、qq_bot_recent、qq_bot_send。"
        case .system:
            return "- 系统动作：lock_screen、get_screen_time、open_link、run_shortcut、"
                + "go_home、look_at_screen、run_command。"
        case .couple:
            return "- 情侣空间：couple_anniversaries、couple_add_anniversary。"
        case .companion:
            return "- ta主动申请（真开始还要他点头）：ask_to_call、ask_to_see_screen、ask_to_listen_together。"
        case .mcp:
            return "- 外接能力（MCP）：具体工具名以实际下发的列表为准。"
        }
    }
}
