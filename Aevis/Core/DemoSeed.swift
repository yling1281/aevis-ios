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
///     -aevisOpenMemoryWeb      再往里推一层，直接打开**记忆网**（截图用）
///     -aevisOpenMoments        直接打开朋友圈
///     -aevisOpenTogether       直接打开一起听
///     -aevisSelfCheck          自检页
///     -aevisShowGate           强制显示「未授权」门禁页（实现在 DeviceGate 里）
///     -aevisSkipGate           跳过授权门禁（-aevisDemo 已隐含跳过）
///     ⭐ 2026-10-06：`-aevisSkipGate` / `-aevisDemo` 现在**也跳过「用户协议」门**
///        （判据在 `AgreementStore.init()` 里，两处必须一致）—— 协议门在 App 最外层，
///        不跳过的话每一张截图都会拍到协议页，自检全废。
///     -aevisShowAgreement      **强制显示协议页**（本机存过同意也照样显示，给截图用）
///     -aevisCallHistory        往聊天里塞一条通话记录
///     -aevisCompanionAsk       显示一条「ta 想…」的申请条
///     -aevisChatHistory=24     往当前对话塞 24 条 —— **专门验「打开是不是停在最新那条」**
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
        seedLongHistory(intArg(args, "-aevisChatHistory"))
        applyToggles(args)
        seedProfile()
        seedMemory()
        seedMoments()
        seedDiaryAndTodo()
        #endif
    }

    /// 从 `-名字=123` 这种参数里抠出数字（没有就返回 0）。
    private static func intArg(_ args: [String], _ name: String) -> Int {
        let prefix = name + "="
        for a in args where a.hasPrefix(prefix) {
            return Int(a.dropFirst(prefix.count)) ?? 0
        }
        return 0
    }

    /// `-aevisChatHistory=24`：往当前对话里塞 N 条，**专门用来验「打开停在哪儿」**。
    ///
    /// ⚠️ 为什么非要有这个：截图里只有 3-4 条消息时**一屏就装下了**，
    /// 滚动/贴底对不对**根本看不出来** —— 用户报了很多次的
    /// 「打开聊天停在最上面」就是这么一直漏掉的。
    /// 塞到一屏半，截图上「停在最新那条」还是「停在最上面」一眼就分得出。
    private static func seedLongHistory(_ n: Int) {
        guard n > 0 else { return }
        let chat = ChatStore.shared
        let lines = [
            "在干嘛", "刚吃完饭", "你吃了吗", "嗯，吃的面", "好吃吗",
            "一般般", "那下次换一家", "好", "今天有点累", "早点睡",
            "你也是", "晚安", "怎么不说话了", "我在呢", "嗯嗯",
            "明天几点起", "八点", "那我叫你", "行", "别忘了",
            "忘不了", "哈哈", "傻样", "睡吧",
        ]
        for i in 0..<n {
            let text = lines[i % lines.count]
            chat.append(ChatMessage(role: i % 2 == 0 ? .user : .assistant,
                                    text: "\(text)（第 \(i + 1) 条）"))
        }
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
        memory.add("答应过带 ta 去看一次海", kind: .promise, quiet: true)
        memory.statusLine = "记住了 4 条。"

        // ⭐ 记忆网演示：真实环境里这些线是让 ta 自己织出来的
        //    （`MemoryStore.weaveLinks` 会调一次模型），可模拟器里没有 API Key、
        //    织不了 —— 所以这里手工连几条，好让那张截图真的看得出「一条连一条」，
        //    而不是四个孤零零的点。
        var seeded = memory.items
        func link(_ a: Int, _ b: Int) {
            guard a != b else { return }
            seeded[a].links = Array(Set((seeded[a].links ?? []) + [seeded[b].id])).sorted()
            seeded[b].links = Array(Set((seeded[b].links ?? []) + [seeded[a].id])).sorted()
        }
        let home = seeded.firstIndex { $0.text.hasPrefix("住在杭州") }
        let job = seeded.firstIndex { $0.text.hasPrefix("九月刚换了工作") }
        let sea = seeded.firstIndex { $0.text.hasPrefix("答应过带") }
        let taste = seeded.firstIndex { $0.text.hasPrefix("不吃香菜") }
        // 住哪 → 换了工作 → 说好一起去看海（同一条线上的三件事）
        if let home, let job { link(home, job) }
        if let job, let sea { link(job, sea) }
        // 口味挂在「住哪」上 —— 同一个人的生活细节
        if let home, let taste { link(home, taste) }
        seeded.forEach { memory.update($0) }
    }

    /// 朋友圈截图要有内容可看，不然只能截到一个空状态。
    private static func seedMoments() {
        let store = MomentStore.shared
        guard store.moments.isEmpty else { return }

        // 时间往前推一点，让「几小时前」这种相对时间看起来正常
        _ = store.post(text: "今天走了很多路，脚有点酸。但是天气很好。", author: .me)
        _ = store.post(text: "刚煮了面，加了两个蛋。一个人吃也挺香的。", author: .ta)

        if let first = store.moments.first {
            store.toggleLike(first)  // ta给我点了赞
        }
        if let hers = store.moments.first(where: { $0.author == .ta }) {
            store.comment("少放点盐", on: hers, author: .me)
            store.comment("知道啦，今天就放了一点点", on: hers, author: .ta)
        }
        store.statusLine = nil
    }

    /// ⭐ 2026-10-04：日记 / 待办也要有内容，不然截图只能截到空状态。
    /// （这两块都是「按人分开存」的，所以必须在 `seedContacts` 选好人之后再塞。）
    private static func seedDiaryAndTodo() {
        let diary = DiaryStore.shared
        if diary.entries.isEmpty {
            var first = DiaryEntry()
            first.date = Date()
            first.title = "今天去看海了"
            first.body = "风有点大，头发全糊在脸上。\(Pronoun.current)说下次要带我坐一次船。"
            first.mood = "开心"
            first.authorIsMe = true
            diary.add(first)

            var reply = DiaryEntry()
            reply.date = Date()
            reply.title = "记一件小事"
            reply.body = "他今天走路走神，差点撞到电线杆。记下来，以后笑他。"
            reply.mood = "想你"
            reply.authorIsMe = false
            diary.add(reply)
        }

        let todo = TodoStore.shared
        if todo.items.isEmpty {
            var a = TodoItem()
            a.title = "一起去看一次海"
            a.note = "等天气暖和一点"
            todo.add(a)

            var b = TodoItem()
            b.title = "陪\(Pronoun.current)把你那首歌听完"
            todo.add(b)

            var c = TodoItem()
            c.title = "给\(Pronoun.current)做一顿饭"
            c.done = true
            c.doneAt = Date()
            todo.add(c)
        }
    }

    private static func seedMessages() {
        let store = PersonaStore.shared
        let chat = ChatStore.shared
        guard let first = store.contacts.first else { return }

        // 确保是在第一个人的对话上写字
        store.select(first.id)

        if chat.messages.isEmpty {
            // 三条分开写是有意的：顺带演示「ta一条一条发」和「单独发一个表情」。
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
        // 所以截图时假装ta已经开着、已经说过话。
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
        // ta主动提的申请那一条（浮在屏幕最上面）
        if args.contains("-aevisCompanionAsk") {
            CompanionRequest.shared.ask(.call, reason: "突然想听听你的声音")
        }
    }
    #endif
}
