import SwiftUI

struct RootView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    /// 授权门禁。**没授权的时候，它挡住整个 App**（2026-09-25 用户明确要求）。
    @StateObject private var gate = DeviceGate.shared
    /// 快捷指令回传来的那一句话，在顶上飘一下就消失。
    @State private var bridgeNote: String?

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
        // 授权通过的那一刻：门禁页淡出、主界面淡入。
        // ⚠️ 盯的是 `gate.authorized` 而不是 `isBlocking` —— 后者是计算属性，
        // 不是 `@Published`，在这里不会触发刷新。
        .animation(.easeInOut(duration: 0.3), value: gate.authorized)
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
        }
        .onChange(of: personaStore.avatarImage) { _, image in
            settings.refreshAvatarTint(from: image)
        }
        .onChange(of: personaStore.activeID) { _, _ in
            settings.refreshAvatarTint(from: personaStore.avatarImage)
        }
        .onChange(of: scenePhase) { _, phase in
            // 进后台就算「这一轮正常结束了」—— 黑匣子靠这一行区分
            //「正常退出」和「崩了 / 被上滑划掉」（后者根本走不到这里）。
            if phase == .background {
                BlackBox.markCleanExit()
                return
            }

            // 每次回到前台，为接下来 24 小时重排一次「不定时」消息 ——
            // 本地通知只能在排程时定下时间，这是能做到的最接近随机的办法。
            guard phase == .active else { return }
            Task { await ProactiveService.shared.reschedule() }

            // 回到前台顺手问一句「我这个账号还在不在」——
            // 卖家在后台把账号删掉之后，这台设备就该**立刻退回未授权**，
            // 但**本地数据一条都不动**（人设、聊天、记忆全留着）。
            Task { await DeviceGate.shared.verifyAccountStillThere() }

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

    /// 授权门禁。
    ///
    /// 用户 2026-09-25 的口径：「打开 APP 就提示没有授权，然后就展示设备码
    /// 和没有授权的那个界面」「填设备码之后就自动通过，就是一个账号一个设备码」。
    ///
    /// **只拦"从没授权过的设备"**：一旦授权过（存在本机），
    /// 以后断网、服务器挂了都照样进 —— 聊天记录都在这台手机里，
    /// 拿网络去锁它等于把用户自己的东西扣住了。
    @ViewBuilder
    private var gated: some View {
        if gate.isBlocking {
            DeviceGateView()
                .transition(.opacity)
        } else {
            normal
                .transition(.opacity)
        }
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
