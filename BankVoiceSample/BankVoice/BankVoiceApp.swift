import SwiftUI

@main
struct BankVoiceApp: App {
    @State private var bank = BankController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            BankView(bank: bank)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { bank.stop() }
                    if phase == .active { bank.refreshAvailability() }
                }
        }
    }
}
