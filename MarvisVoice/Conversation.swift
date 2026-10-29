import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
}

enum ChatPhase: String {
    case idle = "Ready when you are"
    case preparing = "Preparing Marvis"
    case authorizing = "Getting the microphone ready"
    case listening = "Listening to you"
    case transcribing = "Finishing your words"
    case thinking = "Thinking on your iPhone"
    case synthesizing = "Finding my voice"
    case speaking = "Speaking with Marvis"
}

enum VoiceChatError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
