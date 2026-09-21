import AVFoundation
import Foundation
import Observation

enum BankReplyMode: String, CaseIterable, Identifiable {
    case foundation, direct
    var id: String { rawValue }
    var label: String { self == .foundation ? "Foundation Models" : "Direct wording" }
}

enum BankPhase: String {
    case idle = "Ready for your question"
    case preparing = "Preparing Marvis voice"
    case requesting = "Checking the demo bank · 2 seconds"
    case rewriting = "Turning the answer into speech"
    case speaking = "Speaking your answer"
    case listening = "Listening · pause to send"
    case transcribing = "Finishing your question"
}

struct BankMetrics {
    var apiSeconds: Double?
    var firstTextSeconds: Double?
    var firstAudioSeconds: Double?
    var textCompleteSeconds: Double?
    var totalSeconds: Double?
}

/// Owns one cancellable turn, from the mock network wait through playback.
@MainActor @Observable
final class BankController {
    var draft = ""
    var messages: [ChatMessage] = []
    private(set) var phase: BankPhase = .idle
    var error: String?
    private(set) var modelIssue: String?
    private(set) var voiceReady = false
    private(set) var liveTranscript = ""
    private(set) var conversationActive = false
    var mode: BankReplyMode = .foundation
    var readAloud = true
    private(set) var latestJSON = ""
    private(set) var latestEndpoint = ""
    private(set) var metrics = BankMetrics()

    @ObservationIgnored private let api: MockBankAPI
    @ObservationIgnored private let voice = VoiceSynthesizer()
    @ObservationIgnored private let capture = SpeechCapture()
    @ObservationIgnored private let player = PCMPlayer()
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var interruptions: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Double?

    init(api: MockBankAPI = MockBankAPI()) {
        self.api = api
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

    var isBusy: Bool { phase != .idle }
    var canSend: Bool {
        !isBusy && (!readAloud || voiceReady) && (mode == .direct || modelIssue == nil)
    }

    func refreshAvailability() { modelIssue = BankVerbalizer.availabilityIssue }

    func prepareVoice() {
        guard !isBusy else { return }
        error = nil
        phase = .preparing
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                try await voice.prepare()
                try Task.checkCancellation()
                guard operationID == id else { return }
                voiceReady = true
                phase = .idle
                operation = nil
            } catch { fail(error, id: id) }
        }
    }

    func ask(_ scenario: BankScenario) {
        guard canSend else { return }
        send(scenario.query, scenario: scenario)
    }

    func sendDraft() {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !query.isEmpty else { return }
        draft = ""
        send(query)
    }

    private func send(_ query: String, scenario explicitScenario: BankScenario? = nil) {
        guard !isBusy else { return }
        guard query.count <= 500 else {
            conversationActive = false
            draft = query
            error = "Please keep the demo question under 500 characters."
            return
        }
        guard let scenario = explicitScenario ?? BankScenario.route(query) else {
            conversationActive = false
            error = "Try your balance, recent transactions, card status, or an existing payment's status. This demo cannot move money or change an account."
            return
        }
        let selectedMode = mode
        let shouldSpeak = readAloud
        error = nil
        latestJSON = ""
        latestEndpoint = scenario.endpoint
        metrics = BankMetrics()
        startedAt = ProcessInfo.processInfo.systemUptime
        phase = .requesting
        messages.append(ChatMessage(isUser: true, text: query))
        messages.append(ChatMessage(isUser: false, text: ""))
        let index = messages.count - 1
        operationID = UUID()
        let id = operationID
        // Each turn owns its verbalizer. A cancelled turn's context cannot leak
        // into the next customer's facts, even while cancellation unwinds.
        let verbalizer = BankVerbalizer()
        if selectedMode == .foundation { verbalizer.prewarm() }
        operation = Task {
            do {
                let reply = try await api.fetch(scenario)
                try requireCurrent(id)
                metrics.apiSeconds = elapsed
                latestJSON = reply.json
                phase = .rewriting

                let generate: @MainActor (@escaping @MainActor (String) -> Void) async throws -> Void = { receive in
                    let update: @MainActor (String) -> Void = { snapshot in
                        guard self.operationID == id, !Task.isCancelled else { return }
                        if self.metrics.firstTextSeconds == nil, !snapshot.isEmpty {
                            self.metrics.firstTextSeconds = self.elapsed
                        }
                        self.messages[index].text = snapshot
                        receive(snapshot)
                    }
                    if selectedMode == .foundation {
                        try await verbalizer.stream(reply: reply, query: query, receive: update)
                    } else {
                        update(reply.directSpeech)
                    }
                    try self.requireCurrent(id)
                    guard !self.messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw VoiceChatError.message("No spoken wording was produced. Try Direct wording in settings.")
                    }
                    self.metrics.textCompleteSeconds = self.elapsed
                }

                if shouldSpeak {
                    player.onDrained = { [weak self] in self?.completeTurn(id: id) }
                    try await StreamingReply.run(style: .sentences, generate: generate) { phrases in
                        try await self.voice.speak(phrases, voiceB: false) { samples, rate in
                            try self.requireCurrent(id)
                            try await self.player.enqueue(samples, sampleRate: rate)
                            try self.requireCurrent(id)
                            if self.metrics.firstAudioSeconds == nil,
                               samples.contains(where: { abs($0) > 0.001 }) {
                                self.metrics.firstAudioSeconds = self.elapsed
                            }
                            self.phase = .speaking
                        }
                    }
                    try requireCurrent(id)
                    player.finish()
                } else {
                    try await generate { _ in }
                    completeTurn(id: id)
                }
            } catch { fail(error, id: id) }
        }
    }

    private var elapsed: Double { ProcessInfo.processInfo.systemUptime - (startedAt ?? ProcessInfo.processInfo.systemUptime) }

    private func requireCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operationID == id else { throw CancellationError() }
    }

    private func completeTurn(id: UUID) {
        guard operationID == id else { return }
        metrics.totalSeconds = elapsed
        startedAt = nil
        phase = .idle
        operation = nil
        if conversationActive { beginListening(after: .milliseconds(250)) }
    }

    func microphoneTapped() {
        if isBusy || conversationActive { stop(); return }
        refreshAvailability()
        guard canSend else { return }
        conversationActive = true
        beginListening()
    }

    private func beginListening(after delay: Duration = .zero) {
        guard conversationActive, canSend else { conversationActive = false; return }
        liveTranscript = ""
        error = nil
        phase = .listening
        operationID = UUID()
        let id = operationID
        operation = Task {
            do {
                if delay > .zero { try await Task.sleep(for: delay) }
                try requireCurrent(id)
                try await capture.start()
                try requireCurrent(id)
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
                try requireCurrent(id)
                liveTranscript = ""
                phase = .idle
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    beginListening(after: .milliseconds(250))
                } else { send(text) }
            } catch { fail(error, id: id) }
        }
    }

    func stop() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        capture.cancel()
        player.stop()
        phase = .idle
        conversationActive = false
        liveTranscript = ""
        startedAt = nil
        messages.removeAll { !$0.isUser && $0.text.isEmpty }
    }

    func reset() {
        stop()
        messages = []
        latestJSON = ""
        latestEndpoint = ""
        metrics = BankMetrics()
        error = nil
    }

    private func fail(_ failure: Error, id: UUID) {
        guard operationID == id else { return }
        stop()
        if !(failure is CancellationError) { error = failure.localizedDescription }
    }
}
