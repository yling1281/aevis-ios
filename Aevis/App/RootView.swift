import SwiftUI

struct RootView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    /// 授权门禁。**没授权的时候，它挡住整个 App**（2026-09-25 用户明确要求）。
    @StateObject private var gate = DeviceGate.shared
    /// 账号状态 —— 退出登录之后要立刻退回登录页，所以得盯着它。
    @ObservedObject private var account = AccountService.shared
    /// 快捷指令回传来的那一句话，在顶上飘一下就消失。
    @State private var bridgeNote: String?
    /// 上次崩了 → **整个屏幕报错误码**（用户 2026-09-26 明确要求）。
    @State private var showCrash = RootView.shouldShowCrashReport

    /// 崩了要不要弹那一屏。
    ///
    /// ⚠️ 演示/截图跑的时候**必须跳过** —— 否则 30 多张截图全是这一屏
    ///（门禁页刚踩过同样的坑，见 `-aevisShowGate`）。
    private static var shouldShowCrashReport: Bool {
        guard BlackBox.crashedLastRun else { return false }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-aevisDemo") || args.contains("-aevisSkipGate")
            || args.contains("-aevisSelfCheck") {
            return false
        }
        #endif
        return true
    }

    var body: some View {
        ZStack {
            AevisBackground()
            content

            if let bridgeNote {
                VStack {
                    Text(bridgeNote)
                        .font(.aevis(13))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .aevisGlass(cornerRadius: 16)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { self.bridgeNote = nil }
            }
        }
        .animation(.easeOut(duration: 0.22), value: bridgeNote)
        // 上次崩了就先报码 —— **盖在门禁页上面**：
        // 没授权的时候人本来就卡在门禁页，而崩溃码是当下更该看到的东西。
        .fullScreenCover(isPresented: $showCrash) {
            CrashReportView { showCrash = false }
        }
        // 授权通过的那一刻：门禁页淡出、主界面淡入。
        // ⚠️ 盯的是 `gate.authorized` 而不是 `isBlocking` —— 后者是计算属性，
        // 不是 `@Published`，在这里不会触发刷新。
        .animation(.easeInOut(duration: 0.3), value: gate.authorized)
        // 登录 / 退出登录也一样要淡：退出之后退回登录页，不能"啪"一下硬切。
        .animation(.easeInOut(duration: 0.3), value: account.isSignedIn)
        // 快捷指令最后一步「打开 URL」打开的就是这里 ——
        // 这是我们唯一能把数据收回来的通道（run-shortcut 没有返回值）。
        .onOpenURL { url in
            bridgeNote = AevisBridge.handle(url)
        }
        .onChange(of: bridgeNote) { _, note in
            guard note != nil else { return }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                bridgeNote = nil
            }
        }
        // 主题色跟着头像走：头像换了就重算一次主色。
        // **只在这里算** —— 放到 accentColor 那个属性里现算会把界面拖死。
        .onAppear {
            settings.refreshAvatarTint(from: personaStore.avatarImage)
            // 冷启动不会走 scenePhase 的 active 变化，所以这里也补一次
            if settings.qqBotEnabled {
                QQBotService.shared.reconnectIfNeeded()
            }
            // 她"弹出来过但还没进聊天"的那几句话，补进聊天记录
            // （用户 2026-09-29：「弹窗出来的消息是要联动到消息里面去的」）。
            Task { await ProactiveService.shared.deliverPendingToChat() }
        }
        .onChange(of: personaStore.avatarImage) { _, image in
            settings.refreshAvatarTint(from: image)
        }
        .onChange(of: personaStore.activeID) { _, _ in
            settings.refreshAvatarTint(from: personaStore.avatarImage)
        }
        .onChange(of: scenePhase) { _, phase in
            // 进后台 / 失去活跃就算「这一轮正常结束了」—— 黑匣子靠这一行区分
            //「正常退出」和「真的崩了」。
            //
            // ⚠️ **`.inactive` 也要算**（2026-09-26 加的）：用户**上滑划掉** App 之前
            // 一定会先经过 inactive，而以前只有 `.background` 才打标记 ——
            // 于是每次手动划掉都被记成"崩溃"，后台被假报告灌满。
            // 代价是"在非活跃状态下崩"会漏掉，那种极少，比天天误报值。
            if phase == .background || phase == .inactive {
                BlackBox.markCleanExit()
                return
            }

            // 每次回到前台，为接下来 24 小时重排一次「不定时」消息 ——
            // 本地通知只能在排程时定下时间，这是能做到的最接近随机的办法。
            guard phase == .active else { return }

            // ⭐ **回到前台先把音频会话抢回来。**
            //
            // 用户 2026-09-30 报的：「我去后台的时候系统的灵动岛上面和播放音乐圈没有」。
            // 根因在音频类别（见 `AudioSession` 开头那段）—— 但就算类别对了，
            // 这一路也是必须的：离开 App 这段时间里，来电、Siri、耳机插拔、
            // 别的播放器都可能把会话改掉或让系统把"当前播放"判给别人。
            // 回来不重新声明一次，锁屏那一圈就会一直缺着，而用户看到的是
            // "刚才明明还有"。歌没在放时它是空操作。
            AudioSession.reassertIfPlaying()

            Task { await ProactiveService.shared.reschedule() }

            // 通知弹过、但那次没进聊天的那几句 —— 回前台补上。
            // 跟 onAppear 那次是**两条不同的路**：冷启动走 onAppear，
            // 从后台切回来走这里。少一个就有场景漏。
            Task { await ProactiveService.shared.deliverPendingToChat() }

            // 回到前台顺手问一句「我这个账号还在不在」——
            // 卖家在后台把账号删掉之后，这台设备就该**立刻退回未授权**，
            // 但**本地数据一条都不动**（人设、聊天、记忆全留着）。
            Task { await DeviceGate.shared.verifyAccountStillThere() }

            // 封禁：回到前台也立刻问一次，不等下面那轮 30 秒的。
            // 用户切回 App 的那一下，正是最该知道"我还能不能用"的时刻。
            Task { await DeviceGate.shared.refresh() }

            // QQ 机器人：后台被系统掐掉的连接，回到前台要自己接上。
            // （它靠 SilentKeeper 的静音音频尽量活着，但系统真要掐也没辙。）
            if settings.qqBotEnabled {
                QQBotService.shared.reconnectIfNeeded()
            }

            // 顺手看看她该不该发朋友圈了（后台跑不了模型，只能回到前台补）
            let persona = personaStore.persona
            guard persona.isComplete else { return }
            let config = settings.llm
            let memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
            Task {
                await MomentStore.shared.catchUpIfNeeded(
                    persona: persona,
                    config: config,
                    memory: memory
                )
            }
        }
        // ⚠️ **封禁轮询挂在根视图上，不是挂在门禁页上。**
        //
        // 挂门禁页看着更"就近"，但**一授权那页就消失了**，之后没人再查 ——
        // 这就是「后台封了设备、App 照用」的两个原因之一
        // （另一个是 `refresh()` 以前压根没读 `blocked` 字段）。
        // 两个叠一起，封禁等于没生效。
        //
        // 30 秒一次：封禁不需要秒级实时，但也不能拖到"下次启动才生效"。
        // 只在前台跑（`.task` 随视图消失自动取消），后台不耗电。
        .task {
            while !Task.isCancelled {
                await DeviceGate.shared.refresh()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
        .onAppear {
            // 冷启动不会触发 scenePhase 的 active 变化，所以这里也补一次
            let persona = personaStore.persona
            guard persona.isComplete else { return }
            let config = settings.llm
            let memory = settings.memoryInjectEnabled ? MemoryStore.shared.injectedLines() : []
            Task {
                await MomentStore.shared.catchUpIfNeeded(
                    persona: persona,
                    config: config,
                    memory: memory
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-aevisSelfCheck") {
            // CI 用：把自检结果画出来，截图里就能看到过没过
            SelfCheckView()
        } else {
            gated
        }
        #else
        gated
        #endif
    }

    /// 授权门禁（**第一道**）。
    ///
    /// 用户 2026-09-25 的口径：「打开 APP 就提示没有授权，然后就展示设备码
    /// 和没有授权的那个界面」「填设备码之后就自动通过，就是一个账号一个设备码」。
    ///
    /// **只拦"从没授权过的设备"**：一旦授权过（存在本机），
    /// 以后断网、服务器挂了都照样进 —— 聊天记录都在这台手机里，
    /// 拿网络去锁它等于把用户自己的东西扣住了。
    ///
    /// 顺序（用户 2026-09-28 定的）：「先那个设备码，然后你还要登录账号」——
    /// 所以**设备码在前、账号在后**，两道都过才进主界面。
    @ViewBuilder
    private var gated: some View {
        if gate.isBlocking {
            DeviceGateView()
                .transition(.opacity)
        } else if needsLogin {
            LoginView()
                .transition(.opacity)
        } else {
            normal
                .transition(.opacity)
        }
    }

    /// 要不要先登录账号（**第二道门**）。
    ///
    /// 用户原话：「你一定要强制性登录的，去退出登录的话，就回到初始界面，就要登录账号」。
    ///
    /// 两道刻意留的口子：
    ///  · **只拦"从没登录过"的**。本地有 token（`isSignedIn`）就放行 ——
    ///    断网、服务器挂了照样进（`isSignedIn` 只看本地有没有 token，不联网）。
    ///  · **截图自检要能跳过**：CI 那 36 张图全走 `-aevisDemo`，
    ///    被登录门拦住的话每张都会变成登录页。
    ///    `-aevisForceLogin` 是专门用来看登录页那张截图的。
    private var needsLogin: Bool {
        guard account.isConfigured else { return false }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-aevisForceLogin") { return true }
        if args.contains("-aevisDemo") || args.contains("-aevisSkipGate") { return false }
        #endif
        return !account.isSignedIn
    }

    @ViewBuilder
    private var normal: some View {
        if personaStore.isEmpty {
            // 一个联系人都没有 —— 先把「她」造出来。
            // 建好之后落到主界面（默认进的是通讯录）。
            PersonaEditorView(isFirstRun: true)
        } else {
            MainTabView()
        }
    }
}
