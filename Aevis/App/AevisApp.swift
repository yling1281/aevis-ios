import SwiftUI

@main
struct AevisApp: App {
    @StateObject private var personaStore = PersonaStore.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var chat = ChatStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(personaStore)
                .environmentObject(settings)
                .environmentObject(chat)
        }
    }
}
