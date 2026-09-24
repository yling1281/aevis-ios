import SwiftUI

struct RootView: View {
    @EnvironmentObject private var personaStore: PersonaStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            AevisBackground()

            if personaStore.persona.isComplete {
                ChatView()
            } else {
                PersonaEditorView(isFirstRun: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 每次回到前台，为接下来 24 小时重排一次「不定时」消息 ——
            // 本地通知只能在排程时定下时间，这是能做到的最接近随机的办法。
            guard phase == .active else { return }
            Task { await ProactiveService.shared.reschedule() }
        }
    }
}
