import AVFoundation
import Speech

/// A turn is complete only after recognition has produced words and both the
/// microphone and transcription have settled. The clock is supplied by callers
/// so pauses and recognizer delays can be tested without a microphone.
struct UtteranceDetector {
    enum Event: Equatable { case utteranceEnded, noSpeech }

    var silenceDuration: TimeInterval = 1.1
    var noSpeechTimeout: TimeInterval = 30
    var maximumCaptureDuration: TimeInterval = 50
    var speechThreshold: Float = -42

    private let startedAt: TimeInterval
    private var lastSoundAt: TimeInterval?
    private var lastTextAt: TimeInterval?
    private var text = ""
    private var emitted = false
    private var firstAudioAt: TimeInterval?
    private var calibrationSamples = 0
    private var noiseFloor: Float = -60

    init(startedAt: TimeInterval) { self.startedAt = startedAt }

    mutating func recordAudio(decibels: Float, at time: TimeInterval) {
        guard !emitted, decibels.isFinite else { return }
        if firstAudioAt == nil { firstAudioAt = time }
        if text.isEmpty, time - (firstAudioAt ?? time) < 0.25 {
            // Measure the room before words arrive. A fan can be much louder
            // than a fixed silence threshold without being ongoing speech.
            calibrationSamples += 1
            noiseFloor += (decibels - noiseFloor) / Float(calibrationSamples)
            return
        }
        let threshold = max(speechThreshold, noiseFloor + 10)
        if decibels >= threshold {
            lastSoundAt = max(lastSoundAt ?? time, time)
        } else {
            // Follow slow changes in background level without learning active
            // speech as noise when recognition updates temporarily stall.
            noiseFloor += (decibels - noiseFloor) * 0.04
        }
    }

    mutating func recordTranscript(_ transcript: String, at time: TimeInterval) {
        guard !emitted else { return }
        let updated = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard updated != text else { return }
        text = updated
        if !updated.isEmpty { lastTextAt = time }
    }

    mutating func poll(at time: TimeInterval) -> Event? {
        guard !emitted else { return nil }
        if text.isEmpty {
            // Noise alone never sends a message. Recycle the recognition task
            // before the system's recognition-session limit is reached.
            return time - startedAt >= noSpeechTimeout ? emit(.noSpeech) : nil
        }
        let lastActivity = max(lastSoundAt ?? startedAt, lastTextAt ?? startedAt)
        if time - lastActivity >= silenceDuration || time - startedAt >= maximumCaptureDuration {
            return emit(.utteranceEnded)
        }
        return nil
    }

    mutating func finish() -> Event? {
        guard !emitted else { return nil }
        return emit(text.isEmpty ? .noSpeech : .utteranceEnded)
    }

    private mutating func emit(_ event: Event) -> Event {
        emitted = true
        return event
    }
}

@MainActor
final class SpeechCapture {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false
    private var transcript = ""
    private var token = UUID()
    private var finalReceived = false
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var endpointMonitor: Task<Void, Never>?
    private var detector: UtteranceDetector?
    var onText: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onUtteranceEnded: (() -> Void)?
    var onNoSpeech: (() -> Void)?

    func start() async throws {
        cancel()
        let current = token
        let mic = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        guard mic else { throw VoiceChatError.message("Allow microphone access for Bank Voice in Settings → Privacy & Security → Microphone.") }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        try Task.checkCancellation()
        guard token == current else { throw CancellationError() }
        guard speech == .authorized else {
            throw VoiceChatError.message("Allow speech recognition for Bank Voice in Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw VoiceChatError.message("English on-device speech recognition is unavailable. Enable English dictation and let its language assets download, then try again. You can still type a message.")
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [])
        try audioSession.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        transcript = ""
        finalReceived = false
        detector = UtteranceDetector(startedAt: ProcessInfo.processInfo.systemUptime)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            throw VoiceChatError.message("No microphone input is available.")
        }
        // Build the callback outside MainActor: audio taps run on an audio thread.
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.audioTap(for: request) { @Sendable [weak self] decibels, time in
            Task { @MainActor in
                guard let self, self.token == current else { return }
                self.detector?.recordAudio(decibels: decibels, at: time)
            }
        })
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            // The speech framework reports a quiet recognition session this way.
            let noSpeech = (error as NSError?)?.domain == "kAFAssistantErrorDomain" && (error as NSError?)?.code == 1110
            Task { @MainActor in
                guard let self, self.token == current else { return }
                if let text {
                    self.transcript = text
                    self.detector?.recordTranscript(text, at: ProcessInfo.processInfo.systemUptime)
                    self.onText?(text)
                }
                if final {
                    self.finalReceived = true
                    self.stopInput()
                    if self.continuation != nil {
                        self.completeFinish()
                    } else if let event = self.detector?.finish() {
                        self.handleEndpoint(event)
                    }
                } else if let failure {
                    self.stopInput()
                    if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Preserve a useful partial transcript if recognition
                        // terminates before delivering its final result.
                        self.finalReceived = true
                        if self.continuation != nil {
                            self.completeFinish()
                        } else if let event = self.detector?.finish() {
                            self.handleEndpoint(event)
                        }
                    } else if noSpeech {
                        self.handleEndpoint(.noSpeech)
                    } else {
                        self.cancel()
                        self.onFailure?(failure)
                    }
                }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
        endpointMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.token == current else { return }
                if let event = self.detector?.poll(at: ProcessInfo.processInfo.systemUptime) {
                    self.handleEndpoint(event)
                    return
                }
            }
        }
    }

    private nonisolated static func audioTap(
        for request: SFSpeechAudioBufferRecognitionRequest,
        reportLevel: @escaping @Sendable (Float, TimeInterval) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var power: Float = 0
            for index in 0..<Int(buffer.frameLength) { power += samples[index] * samples[index] }
            let decibels = 10 * log10(max(power / Float(buffer.frameLength), 1e-12))
            reportLevel(decibels, ProcessInfo.processInfo.systemUptime)
        }
    }

    private func handleEndpoint(_ event: UtteranceDetector.Event) {
        endpointMonitor?.cancel()
        endpointMonitor = nil
        switch event {
        case .utteranceEnded:
            stopInput()
            request?.endAudio()
            onUtteranceEnded?()
        case .noSpeech:
            if continuation != nil {
                completeFinish()
            } else {
                cancel()
                onNoSpeech?()
            }
        }
    }

    func finish() async throws -> String {
        guard request != nil else { throw CancellationError() }
        endpointMonitor?.cancel()
        endpointMonitor = nil
        detector = nil
        stopInput()
        request?.endAudio()
        if finalReceived {
            let result = transcript
            cancel()
            return result
        }
        return try await withCheckedThrowingContinuation { pending in
            continuation = pending
            recognitionTask?.finish()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.completeFinish()
            }
        }
    }

    private func completeFinish() {
        guard let continuation else { return }
        self.continuation = nil
        let result = transcript
        cancel()
        continuation.resume(returning: result)
    }

    private func stopInput() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    }

    func cancel() {
        token = UUID()
        timeout?.cancel()
        timeout = nil
        endpointMonitor?.cancel()
        endpointMonitor = nil
        detector = nil
        stopInput()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
