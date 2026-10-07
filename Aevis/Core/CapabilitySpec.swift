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
        case .browser:
            return "- 浏览器（真的在网页上操作，你看得见同一个页面）：browser_open 打开淘宝/天猫/京东/"
                + "拼多多/美团/饿了么这些真网站，browser_read 看当前页有什么，browser_click 点，"
                + "browser_type 填，browser_scroll 翻页，browser_back 后退。"
                + "付款、提交订单那最后一下必须让他自己点，你只把页面停在待付款。"
        case .music:
            return "- 音乐：search_music、play_music、music_control、current_lyric、my_music、save_to_her_playlist。"
        case .moment:
            return "- 朋友圈：post_moment、read_moments。"
        case .pan:
            return "- 百度网盘：list_pan_files、read_pan_file。"
        case .qq:
            return "- QQ：qq_contacts、qq_read_messages、qq_send_message、qq_bot_recent、qq_bot_send。"
        case .system:
            // ⚠️ `run_command` 后面那句说明**不能省**（2026-10-07 加）。
            //
            // 老板原话：「APP 意识不到，它自己有一个 Linux，然后还有一些其他的，懂吗？很怪」。
            // 真机上那台命令台是**一整套真的 Alpine Linux**（`AlpineShell`）——
            // 只报一个工具名 `run_command`，ta 会以为它跟 `date`、`ls` 一个量级，
            // 用户让它 `apk add python3` 它就答「我做不到」。
            //
            // ⚠️ 模拟器 / 没 rootfs 时回落到 `BuiltinShell`（几十个内建命令的阉割版）——
            //    那时候**必须说实话**，否则等于教 ta 承诺它做不到的事。
            // ⚠️ `AlpineShell.isAvailable` 只读 `AlpineRuntime` 的**纯 Swift 状态**，
            //    里面没有任何 C 调用，所以从这儿问它是安全的。
            var line = "- 系统动作：lock_screen、get_screen_time、open_link、run_shortcut、"
                + "go_home、look_at_screen、run_command"
            if AlpineShell.shared.isAvailable {
                line += "（这个命令台是一整套真的 Alpine Linux，就在这台手机里跑着："
                    + "完整 shell 能用，apk 包管理器也能用 —— apk add python3 / nodejs / git 都行，"
                    + "装完就留着；还能联网 curl / wget。要写文件、批量处理文本、跑脚本、"
                    + "抓网页原文、算复杂的东西，用它。）"
            } else {
                line += "（这台命令台是内置的精简版，只有几十个常用命令，不是真 Linux）"
            }
            return line + "。"
        case .couple:
            return "- 情侣空间：couple_anniversaries、couple_add_anniversary。"
        case .companion:
            return "- ta主动申请（真开始还要他点头）：ask_to_call、ask_to_see_screen、ask_to_listen_together。"
        case .mcp:
            return "- 外接能力（MCP）：具体工具名以实际下发的列表为准。"
        }
    }
}
