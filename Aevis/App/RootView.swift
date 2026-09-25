import SwiftUI

struct RootView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

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
        .onChange(of: scenePhase) { _, phase in
            // 每次回到前台，为接下来 24 小时重排一次「不定时」消息 ——
            // 本地通知只能在排程时定下时间，这是能做到的最接近随机的办法。
            guard phase == .active else { return }
            Task { await ProactiveService.shared.reschedule() }

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
            normal
        }
        #else
        normal
        #endif
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
