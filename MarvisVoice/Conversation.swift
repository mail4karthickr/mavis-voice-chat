import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
    /// The backend's raw reply that this message summarizes.
    var json: String?
    /// Marvis's diagnostics line for this spoken reply.
    var report: String?
}

enum ChatPhase: String {
    case idle = "Ready when you are"
    case preparing = "Preparing Marvis"
    case authorizing = "Getting the microphone ready"
    case listening = "Listening to you"
    case transcribing = "Finishing your words"
    case fetching = "Asking the backend"
    case thinking = "Summarizing on your iPhone"
    case synthesizing = "Finding my voice"
    case speaking = "Speaking with Marvis"
}

enum VoiceChatError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
