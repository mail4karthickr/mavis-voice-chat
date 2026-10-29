import Foundation
import FoundationModels
import Observation

/// Expressive on-device speech for text and streamed Foundation Models replies.
///
/// Drop the `Marvis` folder into an iOS 26 app target that links the `MLXAudioTTS`
/// product of mlx-audio-swift. Everything else in the folder is an implementation detail.
///
///     let marvis = Marvis()
///     try await marvis.speak("Hello there.")
///
///     let session = LanguageModelSession()
///     try await marvis.speak(session.streamResponse(to: "Tell me a fun fact")) { text in
///         reply = text   // the reply so far, for display
///     }
///
/// Each `speak` call returns after the last sample has played. Starting a new one,
/// calling `stop()`, or cancelling the calling task interrupts the current speech.
@MainActor @Observable
public final class Marvis {
    public enum Voice: Sendable {
        case conversationalA
        case conversationalB
    }

    /// How each element of a text stream relates to the previous one.
    public enum StreamFormat: Sendable {
        /// Each element is the whole reply so far, as Foundation Models snapshots are.
        case cumulative
        /// Each element is new text to append, such as token deltas.
        case incremental
    }

    public var voice: Voice
    /// True once the model has been downloaded and loaded into memory.
    public private(set) var isPrepared = false
    public private(set) var isSpeaking = false
    /// Called once per `speak` when its first audio reaches the speaker.
    @ObservationIgnored public var onPlaybackStart: (@MainActor () -> Void)?

    @ObservationIgnored private let synthesizer = MarvisSynthesizer.shared
    @ObservationIgnored private let player = MarvisPCMPlayer()
    @ObservationIgnored private var current: Task<Void, Error>?
    @ObservationIgnored private var currentID = UUID()
    @ObservationIgnored private var playbackStarted = false
    @ObservationIgnored private var playback: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    public init(voice: Voice = .conversationalA) {
        self.voice = voice
    }

    /// Downloads the model on first use (about 250 MB) and loads it. Optional, since
    /// `speak` loads on demand, but calling it early keeps loading out of the first reply.
    public func prepare() async throws {
        try await synthesizer.prepare(voiceB: voice == .conversationalB)
        isPrepared = true
    }

    /// Speaks a complete piece of text.
    public func speak(_ text: String) async throws {
        try await perform {
            let (phrases, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            continuation.yield(text)
            continuation.finish()
            try await self.synthesize(phrases)
        }
    }

    /// Speaks a streamed reply while it is still being generated.
    /// `onText` receives the full reply so far each time the stream advances.
    public func speak<Text: AsyncSequence>(
        _ stream: Text,
        format: StreamFormat = .cumulative,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws where Text.Element == String {
        try await perform {
            try await MarvisStreamingReply.run(
                style: .natural,
                generate: { receive in
                    var reply = ""
                    for try await element in stream {
                        reply = format == .cumulative ? element : reply + element
                        onText?(reply)
                        receive(reply)
                    }
                },
                speak: { phrases in try await self.synthesize(phrases) }
            )
        }
    }

    /// Speaks a Foundation Models reply as it streams: pass `session.streamResponse(to:)` directly.
    public func speak(
        _ response: LanguageModelSession.ResponseStream<String>,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws {
        try await speak(response.map { $0.content }, format: .cumulative, onText: onText)
    }

    /// Stops generation and playback immediately. The interrupted `speak` throws `CancellationError`.
    public func stop() {
        current?.cancel()
        player.stop()
        if let playback {
            self.playback = nil
            playback.continuation.resume(throwing: CancellationError())
        }
        isSpeaking = false
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async throws {
        // The synthesizer serves one utterance at a time, so let the previous one unwind first.
        while let previous = current {
            stop()
            _ = await previous.result
        }
        try Task.checkCancellation()
        let id = UUID()
        currentID = id
        isSpeaking = true
        playbackStarted = false
        let task = Task {
            defer {
                if self.currentID == id {
                    self.current = nil
                    self.isSpeaking = false
                }
            }
            do {
                try await body()
                try Task.checkCancellation()
                try await self.waitForPlayback()
            } catch {
                if self.currentID == id { self.player.stop() }
                throw error
            }
        }
        current = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func synthesize(_ phrases: AsyncThrowingStream<String, Error>) async throws {
        try await synthesizer.speak(phrases, voiceB: voice == .conversationalB) { samples, rate in
            try await self.player.enqueue(samples, sampleRate: rate)
            if !self.playbackStarted {
                self.playbackStarted = true
                self.onPlaybackStart?()
            }
        }
        isPrepared = true
    }

    private func waitForPlayback() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                playback = (id, continuation)
                player.onDrained = { [weak self] in self?.endPlayback(id, throwing: nil) }
                player.finish()
            }
        } onCancel: {
            Task { @MainActor in self.endPlayback(id, throwing: CancellationError()) }
        }
    }

    private func endPlayback(_ id: UUID, throwing error: Error?) {
        guard let playback, playback.id == id else { return }
        self.playback = nil
        if let error {
            player.stop()
            playback.continuation.resume(throwing: error)
        } else {
            playback.continuation.resume()
        }
    }
}
