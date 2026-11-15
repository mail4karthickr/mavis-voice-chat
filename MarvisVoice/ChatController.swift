import AVFoundation
import FoundationModels
import Observation

/// One turn: voice question → Apple's on-device model → reply spoken as it is written → listen again.
@MainActor @Observable
final class ChatController {
    var messages: [ChatMessage] = []
    var draft = ""
    var liveTranscript = ""
    var phase = ChatPhase.idle
    var error: String?
    var modelIssue: String?
    var readAloud = true
    private(set) var conversationActive = false
    let models = ModelStore()

    /// The engines that can speak now: the iPhone voice and every downloaded model.
    var availableEngines: [Speaker.Engine] { Speaker.Engine.allCases.filter(models.isDownloaded) }
    var engine: Speaker.Engine {
        get { speaker.engine }
        set {
            speaker.engine = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "selectedEngine")
            prepareVoice()
        }
    }
    var voice: Speaker.Voice {
        get { speaker.voice }
        set { speaker.voice = newValue }
    }

    @ObservationIgnored private let speaker = Speaker()
    @ObservationIgnored private let capture = SpeechCapture()
    /// Keeps the conversation so far, so follow-up questions have context.
    @ObservationIgnored private var session: LanguageModelSession?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var interruptions: Task<Void, Never>?

    init() {
        // A saved model may have been removed since; the iPhone voice always works.
        if let saved = Speaker.Engine(rawValue: UserDefaults.standard.string(forKey: "selectedEngine") ?? ""),
           models.isDownloaded(saved) {
            speaker.engine = saved
        }
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
        prepareVoice()
    }

    /// Replies are heard, not read, so the model is asked for speakable text.
    static let modelInstructions = """
        You are a friendly voice assistant. Your replies are spoken aloud, so answer in plain \
        conversational English in one to four sentences and at most 90 words. No markdown, lists, \
        code, emoji, or special symbols. Finish complete sentences.
        """

    static var generationOptions: GenerationOptions {
        GenerationOptions(maximumResponseTokens: 320)
    }

    static let sampleText = "Hi there! This is how I sound. Isn't it a lovely day to try out a new voice?"

    var isBusy: Bool { phase != .idle }
    var canTalk: Bool { modelIssue == nil && !isBusy }

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available: modelIssue = nil
        case .unavailable(.appleIntelligenceNotEnabled):
            modelIssue = "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
        case .unavailable(.modelNotReady):
            modelIssue = "iOS reports that Apple’s on-device model is not ready: its files are missing or still being prepared. Check Settings → Apple Intelligence & Siri, then check again."
        case .unavailable(.deviceNotEligible):
            modelIssue = "Apple Foundation Models requires a supported iPhone with Apple Intelligence."
        case .unavailable:
            modelIssue = "Apple’s on-device model is currently unavailable. Check Apple Intelligence in Settings."
        }
    }

    /// Loads the selected model into memory, so the first reply does not wait for it.
    private func prepareVoice() {
        guard !isBusy, !speaker.isPrepared else { return }
        error = nil
        phase = .preparing
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                try await speaker.prepare()
                try Task.checkCancellation()
                guard operationID == id else { return }
                operation = nil
                phase = .idle
            } catch { fail(error, id: id) }
        }
    }

    /// Speaks a fixed line with the selected voice. Needs no language model.
    func playSample() {
        guard !isBusy else { return }
        error = nil
        phase = .speaking
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                try await speaker.speak(Self.sampleText)
                try Task.checkCancellation()
                guard operationID == id else { return }
                operation = nil
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
        phase = .thinking
        messages.append(ChatMessage(isUser: true, text: text))
        messages.append(ChatMessage(isUser: false, text: ""))
        let index = messages.count - 1
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                let session = self.session ?? LanguageModelSession(model: .default, instructions: Self.modelInstructions)
                self.session = session
                let reply = session.streamResponse(to: text, options: Self.generationOptions)
                let show: @MainActor (String) -> Void = { text in
                    guard self.operationID == id else { return }
                    self.messages[index].text = text
                }
                if readAloud {
                    // The reply goes to the voice while the model is still writing it.
                    speaker.onPlaybackStart = {
                        guard self.operationID == id else { return }
                        self.phase = .speaking
                    }
                    defer { speaker.onPlaybackStart = nil }
                    try await speaker.speak(reply, onText: show)
                    if operationID == id { messages[index].report = speaker.lastReport }
                } else {
                    for try await partial in reply { show(partial.content) }
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                guard !messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw VoiceChatError.message("The model returned no reply. Please try again.")
                }
                completeTurn(id: id)
            } catch { fail(error, id: id) }
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
        speaker.stop()
        // A session accepts one request at a time, and an interrupted reply may still be unwinding.
        if session?.isResponding == true { session = nil }
        liveTranscript = ""
        phase = .idle
        messages.removeAll { !$0.isUser && $0.text.isEmpty }
    }

    func newConversation() {
        stop()
        session = nil
        messages = []
        error = nil
    }

    private func fail(_ failure: Error, id: UUID) {
        guard operationID == id else { return }
        stop()
        // The failed request may have left the session unusable, for example with a full context.
        session = nil
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
}
