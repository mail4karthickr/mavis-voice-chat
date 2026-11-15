import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
    /// The voice's diagnostics line for this spoken reply.
    var report: String?
}

enum ChatPhase: String {
    case idle = "Ready when you are"
    case preparing = "Loading the voice"
    case authorizing = "Getting the microphone ready"
    case listening = "Listening to you"
    case transcribing = "Finishing your words"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

enum VoiceChatError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
