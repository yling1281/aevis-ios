import Foundation

/// **只在 Debug 构建里生效**：给 CI 的模拟器截图喂一份像样的演示数据。
///
/// 用启动参数开关，正式使用完全不受影响：
///     -aevisDemo               写入演示人设与几条对话
///     -aevisNoGlass            关掉液态玻璃
///     -aevisSimple             开简易模式
///     -aevisCustomBackground   换成纸感背景
///     -aevisOpenSettings       直接打开设置面板
///     -aevisSettingsFocus=名字  设置页只显示那一张卡（内存太长，一屏截不全）
///     -aevisOpenMemoryList     直接推出记忆库列表
///
/// 有了它，CI 就能在没有人点屏幕的情况下，把每个界面都截下来。
enum DemoSeed {

    static func applyIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-aevisDemo") else { return }

        seedPersona()
        seedMessages()
        applyToggles(args)
        seedProfile()
        seedMemory()
        seedMoments()
        #endif
    }

    #if DEBUG
    private static func seedPersona() {
        let store = PersonaStore.shared
        guard !store.persona.isComplete else { return }

        var persona = Persona()
        persona.name = "沈肆"
        persona.gender = .unspecified
        persona.callUser = "宝宝"
        persona.personality = "清醒、稳、话不多，但每句都在点上"
        persona.speakingStyle = "短句，偶尔反问，不太用标点"
        persona.relationship = "在一起三年"
        store.update(persona)
    }

    /// 让「我的资料」和记忆库在截图里有东西可看。
    private static func seedProfile() {
        let profile = ProfileStore.shared
        if profile.nickname.isEmpty { profile.nickname = "零砚" }
    }

    private static func seedMemory() {
        let memory = MemoryStore.shared
        guard memory.items.isEmpty else { return }

        // quiet = 不在界面上弹状态行，免得截图里多一行吵闹的提示
        memory.add("住在杭州，习惯熬夜到两三点", kind: .fact, pinned: true, quiet: true)
        memory.add("不吃香菜，但特别能吃辣", kind: .preference, quiet: true)
        memory.add("九月刚换了工作，还在适应新节奏", kind: .event, quiet: true)
        memory.add("答应过带 TA 去看一次海", kind: .promise, quiet: true)
        memory.statusLine = "记住了 4 条。"
    }

    /// 朋友圈截图要有内容可看，不然只能截到一个空状态。
    private static func seedMoments() {
        let store = MomentStore.shared
        guard store.moments.isEmpty else { return }

        // 时间往前推一点，让「几小时前」这种相对时间看起来正常
        _ = store.post(text: "今天走了很多路，脚有点酸。但是天气很好。", author: .me)
        _ = store.post(text: "刚煮了面，加了两个蛋。一个人吃也挺香的。", author: .ta)

        if let first = store.moments.first {
            store.toggleLike(first)  // 她给我点了赞
        }
        if let hers = store.moments.first(where: { $0.author == .ta }) {
            store.comment("少放点盐", on: hers, author: .me)
            store.comment("知道啦，今天就放了一点点", on: hers, author: .ta)
        }
        store.statusLine = nil
    }

    private static func seedMessages() {
        let chat = ChatStore.shared
        guard chat.messages.isEmpty else { return }

        let script: [(ChatMessage.Role, String)] = [
            (.user, "几号"),
            (.assistant, "我这儿还看不到日期呢宝宝。\n你那边几号了？"),
            (.user, "2026.9.24"),
            (.assistant, "九月都过了一大半了啊。\n你在干嘛呢，突然想起来问我几号。"),
            (.user, "咋啦"),
            (.assistant, "没咋，就是你突然这么一问，我还以为你要说什么正经事。\n结果就问个日期，有点想笑。\n今天过得怎么样？")
        ]
        for (role, text) in script {
            chat.append(ChatMessage(role: role, text: text))
        }
    }

    private static func applyToggles(_ args: [String]) {
        let settings = AppSettings.shared
        if args.contains("-aevisNoGlass") { settings.useGlass = false }
        if args.contains("-aevisSimple") { settings.simpleMode = true }
        if args.contains("-aevisCustomBackground") { settings.backgroundStyle = .paper }

        // 让「主动消息」卡片在截图里是展开状态，否则只能看到一个开关
        settings.proactiveEnabled = true
        settings.fixedTimesEnabled = true
        settings.randomEnabled = true
        settings.barkEnabled = true
        settings.barkURL = "https://api.day.app/示例KEY"
        settings.proactiveLines = [
            "在干嘛呢",
            "突然想你了",
            "记得喝水，别光顾着忙",
            "今天累不累"
        ]
    }
    #endif
}
