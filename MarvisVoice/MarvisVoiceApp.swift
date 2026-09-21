import SwiftUI

@main
struct MarvisVoiceApp: App {
    @State private var chat = ChatController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ChatView(chat: chat)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { chat.stop() }
                    if phase == .active { chat.refreshAvailability() }
                }
        }
    }
}
