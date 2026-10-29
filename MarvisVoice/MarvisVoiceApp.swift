import SwiftUI

@main
struct MarvisVoiceApp: App {
    @State private var marvis: Marvis
    @State private var chat: ChatController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let marvis = Marvis()
        _marvis = State(initialValue: marvis)
        _chat = State(initialValue: ChatController(marvis: marvis))
    }

    var body: some Scene {
        WindowGroup {
            HomeView(chat: chat, marvis: marvis)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        chat.stop()
                        marvis.stop()
                    }
                    if phase == .active { chat.refreshAvailability() }
                }
        }
    }
}
