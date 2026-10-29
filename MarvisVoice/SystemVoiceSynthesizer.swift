import AVFoundation

/// Reads the supplied text with an installed system voice. MarvisPCMPlayer remains the
/// only owner of audible playback, including its drain and backpressure rules.
@MainActor
final class SystemVoiceSynthesizer: NSObject, AVSpeechSynthesizerDelegate {
    private struct AudioChunk: Sendable {
        let samples: [Float]
        let sampleRate: Int
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var operation: (id: UUID, task: Task<Void, Error>)?
    private var utteranceID: ObjectIdentifier?
    private var audioContinuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(
        _ phrases: AsyncThrowingStream<String, Error>,
        receive: @escaping @MainActor @Sendable ([Float], Int) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        guard operation == nil else { throw SystemVoiceError.busy }
        guard let voice = Self.preferredVoice() else { throw SystemVoiceError.unavailable }
        let id = UUID()
        let task = Task { @MainActor in
            for try await phrase in phrases {
                try Task.checkCancellation()
                guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                try await self.synthesize(phrase, voice: voice, receive: receive)
            }
            try Task.checkCancellation()
        }
        operation = (id, task)
        defer {
            if operation?.id == id { operation = nil }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func stop() {
        operation?.task.cancel()
        // Cancelling the task also wakes a phrase stream that has not produced
        // any text yet. Finishing PCM wakes a task waiting on the synthesizer.
        audioContinuation?.finish(throwing: CancellationError())
        audioContinuation = nil
        utteranceID = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func synthesize(
        _ text: String,
        voice: AVSpeechSynthesisVoice,
        receive: @MainActor @Sendable ([Float], Int) async throws -> Void
    ) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        let id = ObjectIdentifier(utterance)
        let audio = AsyncThrowingStream<AudioChunk, Error>.makeStream()
        utteranceID = id
        audioContinuation = audio.continuation
        // The API has no failure delegate. A stalled voice must not leave the
        // conversation waiting indefinitely for a first or final PCM buffer.
        var watchdog = Self.watchdog(audio.continuation)
        defer {
            watchdog.cancel()
            if utteranceID == id {
                utteranceID = nil
                audioContinuation = nil
                synthesizer.stopSpeaking(at: .immediate)
            }
        }
        synthesizer.write(utterance, toBufferCallback: Self.audioCallback(audio.continuation))
        var receivedAudio = false
        for try await chunk in audio.stream {
            try Task.checkCancellation()
            receivedAudio = true
            watchdog.cancel()
            try await receive(chunk.samples, chunk.sampleRate)
            watchdog = Self.watchdog(audio.continuation)
        }
        try Task.checkCancellation()
        guard receivedAudio else { throw SystemVoiceError.noAudio }
    }

    private static func watchdog(
        _ continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            continuation.finish(throwing: SystemVoiceError.noAudio)
        }
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let americanEnglish = voices.filter { $0.language == "en-US" }
        let english = voices.filter { $0.language.hasPrefix("en-") }
        let local = voices.filter { $0.language == AVSpeechSynthesisVoice.currentLanguageCode() }
        let candidates = !americanEnglish.isEmpty ? americanEnglish : !english.isEmpty ? english : local
        return candidates.sorted {
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.identifier < $1.identifier
        }.first
    }

    // AVFoundation calls this on its speech thread. Copy the PCM there; neither
    // an AVAudioBuffer nor an actor-isolated closure crosses to that thread.
    private nonisolated static func audioCallback(
        _ continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation
    ) -> AVSpeechSynthesizer.BufferCallback {
        { @Sendable buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                continuation.finish(throwing: SystemVoiceError.unsupportedAudio)
                return
            }
            guard pcm.frameLength > 0 else {
                continuation.finish()
                return
            }
            do { continuation.yield(try copyAudio(pcm)) }
            catch { continuation.finish(throwing: error) }
        }
    }

    private nonisolated static func copyAudio(_ buffer: AVAudioPCMBuffer) throws -> AudioChunk {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard channels > 0, rate.isFinite, rate > 0, rate < Double(Int.max) else {
            throw SystemVoiceError.unsupportedAudio
        }
        let interleaved = buffer.format.isInterleaved
        let sample: (Int, Int) -> Float
        if let data = buffer.floatChannelData {
            sample = { frame, channel in
                interleaved ? data[0][frame * channels + channel] : data[channel][frame]
            }
        } else if let data = buffer.int16ChannelData {
            sample = { frame, channel in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame]) / 32768
            }
        } else if let data = buffer.int32ChannelData {
            sample = { frame, channel in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame]) / 2_147_483_648
            }
        } else {
            throw SystemVoiceError.unsupportedAudio
        }
        var samples = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var value: Float = 0
            for channel in 0..<channels { value += sample(frame, channel) }
            samples[frame] = value / Float(channels)
        }
        return AudioChunk(samples: samples, sampleRate: Int(rate))
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id else { return }
            self.audioContinuation?.finish(throwing: CancellationError())
        }
    }
}

private enum SystemVoiceError: LocalizedError {
    case busy, unavailable, noAudio, unsupportedAudio

    var errorDescription: String? {
        switch self {
        case .busy: "The voice engine is still stopping. Try again shortly."
        case .unavailable: "No system voice is available. Download an English voice in iPhone Settings."
        case .noAudio: "The system voice did not produce audio. Try again or choose a different voice."
        case .unsupportedAudio: "The system voice returned an unsupported audio format."
        }
    }
}
