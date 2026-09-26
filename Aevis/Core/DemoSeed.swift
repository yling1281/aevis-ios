import Foundation

/// **只在 Debug 构建里生效**：给 CI 的模拟器截图喂一份像样的演示数据。
///
/// 用启动参数开关，正式使用完全不受影响：
///     -aevisDemo               写入演示人设（三个联系人）与几条对话
///     -aevisNoGlass            关掉液态玻璃
///     -aevisSimple             开简易模式
///     -aevisCustomBackground   换成纸感背景
///     -aevisOpenTab=名字        直接切到某个 tab（chats / contacts / discover / me）
///     -aevisOpenChat           切到聊天 tab 并进入第一个联系人的对话
///     -aevisOpenSettings       直接打开设置面板
///     -aevisSettingsFocus=名字  设置页只显示那一张卡（内存太长，一屏截不全）
///     -aevisOpenMemoryList     直接推出记忆库列表
///     -aevisOpenMoments        直接打开朋友圈
///     -aevisOpenTogether       直接打开一起听
///     -aevisSelfCheck          自检页
///     -aevisShowGate           强制显示「未授权」门禁页（实现在 DeviceGate 里）
///     -aevisSkipGate           跳过授权门禁（-aevisDemo 已隐含跳过）
///     -aevisCallHistory        往聊天里塞一条通话记录
///     -aevisCompanionAsk       显示一条「TA 想…」的申请条
///
/// 有了它，CI 就能在没有人点屏幕的情况下，把每个界面都截下来。
///
/// ⚠️ `@MainActor`：里面要碰 `MusicPlayer.shared` / `ListenTogetherService.shared`，
/// 而这两个现在都是 `@MainActor` 的。它的唯一调用点是 `AevisApp.init()`（主线程），
/// 所以加上没有任何副作用。
@MainActor
enum DemoSeed {

    static func applyIfRequested() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-aevisDemo") else { return }

        seedContacts()
        seedMessages()
        applyToggles(args)
        seedProfile()
        seedMemory()
        seedMoments()
        #endif
    }

    #if DEBUG
    /// 通讯录里放三个人 —— 截图要能看到「加过好几个联系人」的样子。
    ///
    /// 第一个是默认要聊的那个，所以最后要切回它。
    private static func seedContacts() {
        let store = PersonaStore.shared
        guard store.isEmpty else { return }

        store.add(makePersona(
            name: "沈肆",
            gender: .unspecified,
            callUser: "宝宝",
            personality: "清醒、稳、话不多，但每句都在点上",
            style: "短句，偶尔反问，不太用标点",
            relationship: "在一起三年"
        ))
        store.add(makePersona(
            name: "阿七",
            gender: .female,
            callUser: "哥",
            personality: "语速快、爱打岔、情绪全写在脸上",
            style: "口语，爱用语气词，喜欢连着发好几条",
            relationship: "打游戏认识的搭子"
        ))
        store.add(makePersona(
            name: "老陈",
            gender: .male,
            callUser: "老板",
            personality: "闷，但记性好，答应过的事一定记得",
            style: "一句话说一件事，很少发表情",
            relationship: "认识十年的朋友"
        ))

        if let first = store.contacts.first { store.select(first.id) }
    }

    private static func makePersona(
        name: String,
        gender: GenderIdentity,
        callUser: String,
        personality: String,
        style: String,
        relationship: String
    ) -> Persona {
        var persona = Persona()
        persona.name = name
        persona.gender = gender
        persona.callUser = callUser
        persona.personality = personality
        persona.speakingStyle = style
        persona.relationship = relationship
        return persona
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
        let store = PersonaStore.shared
        let chat = ChatStore.shared
        guard let first = store.contacts.first else { return }

        // 确保是在第一个人的对话上写字
        store.select(first.id)

        if chat.messages.isEmpty {
            // 三条分开写是有意的：顺带演示「她一条一条发」和「单独发一个表情」。
            let script: [(ChatMessage.Role, String)] = [
                (.user, "几号"),
                (.assistant, "我这儿还看不到日期呢宝宝。\n你那边几号了？"),
                (.user, "2026.9.24"),
                (.assistant, "九月都过了一大半了啊。\n你在干嘛呢，突然想起来问我几号。"),
                (.user, "咋啦"),
                (.assistant, "没咋，就是你突然这么一问，我还以为你要说什么正经事。"),
                (.assistant, "[偷笑]"),
                (.assistant, "今天过得怎么样？")
            ]
            for (role, text) in script {
                chat.append(ChatMessage(role: role, text: text))
            }
        }

        // 给第二个人也留两句 —— 会话列表才有多行、预览也不一样
        if store.contacts.count > 1 {
            let second = store.contacts[1]
            store.select(second.id)
            if chat.messages.isEmpty {
                chat.append(ChatMessage(role: .user, text: "今晚还打吗"))
                chat.append(ChatMessage(role: .assistant, text: "打啊"))
                chat.append(ChatMessage(role: .assistant, text: "你先把作业写完"))
            }
            store.select(first.id)
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

        // 播放界面空的没法看 —— 塞一首假歌进去（模拟器里放不出声、也没有封面）
        if args.contains("-aevisOpenPlayer") {
            MusicPlayer.shared.seedDemo()
        }
        // 两个人头像那一行要「一起听」开着才出现，真机上得有 API Key 才会开始 ——
        // 所以截图时假装她已经开着、已经说过话。
        if args.contains("-aevisTogetherDemo") {
            ListenTogetherService.shared.seedDemo()
        }

        // 通话记录那一条（微信那种居中的小字）—— 新加的界面，不塞就截不到。
        if args.contains("-aevisCallHistory"), let contact = PersonaStore.shared.activeID {
            ChatStore.shared.append(
                ChatMessage(role: .system, text: "通话时长 03:21",
                            kind: .call, callSeconds: 201),
                for: contact
            )
        }
        // 她主动提的申请那一条（浮在屏幕最上面）
        if args.contains("-aevisCompanionAsk") {
            CompanionRequest.shared.ask(.call, reason: "突然想听听你的声音")
        }
    }
    #endif
}
