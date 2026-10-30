import AVFoundation
import FoundationModels
import Observation

enum ReplyVoice: String, CaseIterable, Identifiable {
    case system = "iPhone"
    case marvis = "Marvis"
    var id: String { rawValue }
}

/// One turn: voice question → backend JSON → on-device summary → spoken reply → listen again.
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
    /// Hand the summary to Marvis as it is written instead of waiting for the complete text.
    var streamSummary = false
    private(set) var conversationActive = false
    @ObservationIgnored private let marvis: Marvis
    @ObservationIgnored private let backend = MockBackend()
    @ObservationIgnored private let systemVoice = SystemVoiceSynthesizer()
    @ObservationIgnored private let capture = SpeechCapture()
    @ObservationIgnored private let player = MarvisPCMPlayer()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var interruptions: Task<Void, Never>?
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

    /// The on-device model only summarizes; the backend owns the conversation.
    static let modelInstructions = """
        You turn JSON responses from a backend into short spoken answers for a voice assistant.
        Answer the user's question using only the data in the JSON. Use plain spoken English in
        one to three sentences and at most 70 words. No markdown, lists, code, emoji, or field names.
        Do not mention JSON. Finish complete sentences.
        """

    static var generationOptions: GenerationOptions {
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 320)
    }

    static func prompt(question: String, json: String) -> String {
        "The user asked: \"\(question)\"\n\nThe backend returned this JSON:\n\(json)"
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
        phase = .fetching
        messages.append(ChatMessage(isUser: true, text: text))
        messages.append(ChatMessage(isUser: false, text: ""))
        let index = messages.count - 1
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                // 1. The question goes to the backend as text; it answers with JSON.
                let json = try await backend.answer(question: text)
                try Task.checkCancellation()
                guard operationID == id else { return }
                messages[index].json = json
                phase = .thinking
                // 2. The on-device model turns that JSON into a spoken summary.
                let prompt = Self.prompt(question: text, json: json)
                if readAloud && replyVoice == .marvis {
                    if streamSummary {
                        try await streamSummaryToMarvis(prompt, at: index, id: id)
                    } else {
                        // 3. The complete summary is handed to Marvis, as the chat bot app does.
                        try await generate(prompt, at: index, id: id, receive: { _ in })
                        let summary = messages[index].text
                        try await speakWithMarvis(at: index, id: id) { try await marvis.speak(summary) }
                    }
                    try Task.checkCancellation()
                    completeTurn(id: id)
                } else if readAloud {
                    completeTurnWhenDrained(id: id)
                    try await MarvisStreamingReply.run(
                        generate: { receive in
                            try await self.generate(prompt, at: index, id: id, receive: receive)
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
                    try await generate(prompt, at: index, id: id, receive: { _ in })
                    completeTurn(id: id)
                }
            } catch { fail(error, id: id) }
        }
    }

    /// Streams the summary into the shared Marvis voice phrase by phrase.
    private func streamSummaryToMarvis(_ prompt: String, at index: Int, id: UUID) async throws {
        let (replies, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let producer = Task {
            do {
                try await generate(prompt, at: index, id: id) { continuation.yield($0) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { producer.cancel() }
        try await speakWithMarvis(at: index, id: id) { try await marvis.speak(replies) }
    }

    /// Runs one Marvis utterance with phase bookkeeping, then records its diagnostics on the reply.
    private func speakWithMarvis(at index: Int, id: UUID, _ utterance: () async throws -> Void) async throws {
        marvisIsSpeaking = true
        marvis.onPlaybackStart = { [weak self] in
            guard let self, self.operationID == id else { return }
            self.phase = .speaking
        }
        defer {
            marvis.onPlaybackStart = nil
            marvisIsSpeaking = false
            if operationID == id { messages[index].report = marvis.lastReport }
        }
        try await utterance()
    }

    private func generate(_ prompt: String, at index: Int, id: UUID,
                          receive: @escaping @MainActor (String) -> Void) async throws {
        // Each turn summarizes an independent backend response, so each gets a fresh session.
        let session = Self.makeSession()
        for try await partial in session.streamResponse(to: prompt, options: Self.generationOptions) {
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
        conversationActive = false
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
        messages.removeAll { !$0.isUser && $0.text.isEmpty }
    }

    func newConversation() {
        stop()
        messages = []
        error = nil
    }

    private func fail(_ failure: Error, id: UUID) {
        guard operationID == id else { return }
        stop()
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
}
