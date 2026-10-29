import AVFoundation
import FoundationModels
import Observation

enum ReplyVoice: String, CaseIterable, Identifiable {
    case system = "iPhone"
    case marvis = "Marvis"
    var id: String { rawValue }
}

@MainActor @Observable
final class ChatController {
    var messages: [ChatMessage] = []
    var draft = ""
    var liveTranscript = ""
    var phase = ChatPhase.idle
    var error: String?
    var modelIssue: String?
    var voiceReady: Bool { marvis.isPrepared }
    var voiceB: Bool {
        get { marvis.voice == .conversationalB }
        set { marvis.voice = newValue ? .conversationalB : .conversationalA }
    }
    var readAloud = true
    var replyVoice = ReplyVoice(rawValue: UserDefaults.standard.string(forKey: "replyVoice") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(replyVoice.rawValue, forKey: "replyVoice") }
    }
    var contextNotice: String?
    private(set) var conversationActive = false
    @ObservationIgnored private var session = ChatController.makeSession()
    @ObservationIgnored private let marvis: Marvis
    @ObservationIgnored private let systemVoice = SystemVoiceSynthesizer()
    @ObservationIgnored private let capture = SpeechCapture()
    @ObservationIgnored private let player = MarvisPCMPlayer()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var interruptions: Task<Void, Never>?
    @ObservationIgnored private var modelIsResponding = false
    @ObservationIgnored private var marvisIsSpeaking = false

    init(marvis: Marvis) {
        self.marvis = marvis
        refreshAvailability()
        capture.onText = { [weak self] in self?.liveTranscript = $0 }
        capture.onUtteranceEnded = { [weak self] in self?.finishRecording() }
        capture.onNoSpeech = { [weak self] in
            guard let self, self.conversationActive, self.phase == .listening else { return }
            self.phase = .idle
            self.beginListening(after: .milliseconds(250))
        }
        capture.onFailure = { [weak self] message in
            self?.stop()
            self?.error = message
        }
        interruptions = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                self?.stop()
            }
        }
    }

    static let modelInstructions = """
        You are Marvis, a friendly voice companion. Answer in English using natural spoken language.
        Answer the user's latest question directly and stay on that topic. Use the conversation only when relevant.
        Keep the first sentence short and useful. Usually use one to three sentences and at most 70 words.
        Ask one short clarifying question when the request or speech transcript is unclear instead of guessing its meaning.
        Say when you do not know. Do not invent facts, names, quotations, sources, or personal details about the user.
        You run on the user's iPhone. You cannot browse, read their private information, check live conditions,
        or operate their device. Never claim you checked information or performed an action you cannot perform.
        Use plain spoken text without markdown, lists, emoji, or stage directions. Finish complete sentences.
        """

    static var generationOptions: GenerationOptions {
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 320)
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(model: .default, instructions: modelInstructions)
    }

    var isBusy: Bool { phase != .idle }
    var canTalk: Bool { modelIssue == nil && !isBusy && (!readAloud || replyVoice == .system || voiceReady) }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available: modelIssue = nil
        case .unavailable(.appleIntelligenceNotEnabled):
            modelIssue = "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            modelIssue = "Apple’s on-device model is still downloading. Connect to Wi-Fi and power, then check again."
        case .unavailable(.deviceNotEligible):
            modelIssue = "Apple Foundation Models requires a supported iPhone with Apple Intelligence."
        case .unavailable:
            modelIssue = "Apple’s on-device model is currently unavailable. Check Apple Intelligence in Settings."
        }
    }

    func prepareVoice() {
        guard !isBusy else { return }
        error = nil
        phase = .preparing
        let id = operationID
        operation = Task {
            do {
                try await marvis.prepare()
                try Task.checkCancellation()
                guard operationID == id else { return }
                phase = .idle
            } catch { fail(error, id: id) }
        }
    }

    func microphoneTapped() {
        if conversationActive || isBusy {
            stop()
        } else {
            refreshAvailability()
            guard canTalk else { return }
            conversationActive = true
            beginListening()
        }
    }

    private func beginListening(after delay: Duration = .zero) {
        guard conversationActive, !isBusy else { return }
        refreshAvailability()
        guard canTalk else { conversationActive = false; return }
        error = nil
        liveTranscript = ""
        phase = .authorizing
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                try await capture.start()
                try Task.checkCancellation()
                guard operationID == id else { return }
                phase = .listening
            } catch { fail(error, id: id) }
        }
    }

    private func finishRecording() {
        guard phase == .listening else { return }
        phase = .transcribing
        let id = operationID
        operation = Task {
            do {
                let text = try await capture.finish()
                try Task.checkCancellation()
                guard operationID == id else { return }
                phase = .idle
                liveTranscript = ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    beginListening(after: .milliseconds(250))
                } else { send(text) }
            } catch { fail(error, id: id) }
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canTalk else { return }
        draft = ""
        send(text)
    }

    private func send(_ text: String) {
        guard !isBusy else { return }
        guard text.count <= 2000 else {
            conversationActive = false
            draft = text
            error = "Please keep each message under 2,000 characters so it fits the on-device model."
            return
        }
        error = nil
        contextNotice = nil
        phase = .thinking
        messages.append(ChatMessage(isUser: true, text: text))
        messages.append(ChatMessage(isUser: false, text: ""))
        let index = messages.count - 1
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                if readAloud && replyVoice == .marvis {
                    try await speakWithMarvis(text, at: index, id: id)
                    try Task.checkCancellation()
                    completeTurn(id: id)
                } else if readAloud {
                    completeTurnWhenDrained(id: id)
                    try await MarvisStreamingReply.run(
                        generate: { receive in
                            try await self.generate(text, at: index, id: id, receive: receive)
                        },
                        speak: { phrases in
                            try await self.systemVoice.speak(phrases) { samples, rate in
                                guard self.operationID == id else { throw CancellationError() }
                                try await self.player.enqueue(samples, sampleRate: rate)
                                self.phase = .speaking
                            }
                        }
                    )
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    player.finish()
                } else {
                    try await generate(text, at: index, id: id, receive: { _ in })
                    completeTurn(id: id)
                }
            } catch { fail(error, id: id) }
        }
    }

    /// Streams the model's reply into the shared Marvis voice, the same API any host app uses.
    private func speakWithMarvis(_ text: String, at index: Int, id: UUID) async throws {
        let (replies, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producer = Task {
            do {
                try await generate(text, at: index, id: id) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        marvisIsSpeaking = true
        marvis.onPlaybackStart = { [weak self] in
            guard let self, self.operationID == id else { return }
            self.phase = .speaking
        }
        defer {
            producer.cancel()
            marvis.onPlaybackStart = nil
            marvisIsSpeaking = false
        }
        try await marvis.speak(replies)
    }

    private func generate(_ text: String, at index: Int, id: UUID,
                          receive: @escaping @MainActor (String) -> Void) async throws {
        modelIsResponding = true
        defer { if operationID == id { modelIsResponding = false } }
        for attempt in 0..<2 {
            do {
                for try await partial in session.streamResponse(to: text, options: Self.generationOptions) {
                    try Task.checkCancellation()
                    guard operationID == id else { throw CancellationError() }
                    messages[index].text = partial.content
                    receive(partial.content)
                }
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                guard !messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VoiceChatError.message("The model returned no reply. Please try again.")
                }
                if phase == .thinking, readAloud { phase = .synthesizing }
                return
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                try Task.checkCancellation()
                guard operationID == id else { throw CancellationError() }
                // Retry only before any reply was emitted, so spoken words never repeat.
                guard attempt == 0, messages[index].text.isEmpty else {
                    throw VoiceChatError.message("The conversation reached its context limit. Start a new conversation to continue.")
                }
                session = Self.makeSession()
                contextNotice = "A fresh model session started because the conversation reached its context limit. Earlier messages remain visible."
            }
        }
    }

    private func completeTurnWhenDrained(id: UUID) {
        player.onDrained = { [weak self] in
            self?.completeTurn(id: id)
        }
    }

    private func completeTurn(id: UUID) {
        guard operationID == id else { return }
        operation = nil
        phase = .idle
        if conversationActive {
            // Let the speaker's final sound decay before opening the microphone.
            beginListening(after: .milliseconds(250))
        }
    }

    func stop() {
        let interruptedModel = modelIsResponding
        conversationActive = false
        modelIsResponding = false
        operationID = UUID()
        operation?.cancel()
        operation = nil
        capture.cancel()
        systemVoice.stop()
        player.stop()
        // The Marvis instance is shared with other screens; only interrupt speech this chat started.
        if marvisIsSpeaking { marvis.stop() }
        liveTranscript = ""
        phase = .idle
        // A partially generated transcript must not be reused by another request.
        if interruptedModel {
            session = Self.makeSession()
            contextNotice = "Reply interrupted. The next message starts a fresh model session."
        }
        messages.removeAll { !$0.isUser && $0.text.isEmpty }
    }

    func newConversation() {
        stop()
        session = Self.makeSession()
        messages = []
        error = nil
        contextNotice = nil
    }

    private func fail(_ failure: Error, id: UUID) {
        guard operationID == id else { return }
        stop()
        // A stream error can leave an incomplete model transcript even after
        // the generation task has unwound its cancellation bookkeeping.
        session = Self.makeSession()
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
}
