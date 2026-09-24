import SwiftUI

struct RootView: View {
    @EnvironmentObject private var personaStore: PersonaStore

    var body: some View {
        ZStack {
            AevisBackground()

            if personaStore.persona.isComplete {
                ChatView()
            } else {
                PersonaEditorView(isFirstRun: true)
            }
        }
    }
}
