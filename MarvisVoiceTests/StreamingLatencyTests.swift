import Foundation
import FoundationModels
import XCTest
@testable import MarvisVoice

final class StreamingLatencyTests: XCTestCase {
    private typealias ReceiveAudio = @MainActor @Sendable ([Float], Int) async throws -> Void
    private typealias Speak = @MainActor @Sendable (
        AsyncThrowingStream<String, Error>, @escaping ReceiveAudio
    ) async throws -> Void

    /// Exercise the real model, default iPhone voice, and audio queue together. A fake
    /// generator that waits for speech cannot detect device synthesis latency.
    @MainActor
    func testActualAudioStartsBeforeModelFinishesStreaming() async throws {
        try Self.requireDeviceModel()
        let voice = SystemVoiceSynthesizer()
        defer { voice.stop() }
        try await measureLatency(prefix: "STREAMING_LATENCY_SYSTEM", style: .immediate) { phrases, receive in
            try await voice.speak(phrases, receive: receive)
        }
    }

    /// Prepare the expressive voice before measuring, as the app does before
    /// accepting a conversation. Model generation itself runs without delays.
    @MainActor
    func testExpressiveAudioStartsBeforeModelFinishesStreaming() async throws {
        try Self.requireDeviceModel()
        let voice = VoiceSynthesizer()
        try await voice.prepare()
        try Task.checkCancellation()
        try await measureLatency(prefix: "STREAMING_LATENCY_MARVIS", style: .natural) { phrases, receive in
            try await voice.speak(phrases, voiceB: false, receive: receive)
        }
    }

    @MainActor
    private static func requireDeviceModel() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This latency test requires Apple Intelligence and Metal on an iPhone.")
        #else
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple's on-device language model is unavailable.")
        }
        #endif
    }

    @MainActor
    private func measureLatency(
        prefix: String, style: StreamingSpeechText.Style, speak: @escaping Speak
    ) async throws {
        let player = PCMPlayer()
        defer { player.stop() }
        let session = LanguageModelSession(model: .default, instructions: ChatController.modelInstructions)
        let textFinished = expectation(description: "The real language model finishes its response")
        let audibleBuffer = expectation(description: "Non-silent synthesized PCM reaches the audio player")
        let measurements = Measurements(prefix: prefix)
        let operation = Task { @MainActor in
            try await StreamingReply.run(style: style) { receive in
                for try await snapshot in session.streamResponse(
                    to: "Explain how rain forms.",
                    options: ChatController.generationOptions
                ) {
                    try Task.checkCancellation()
                    if measurements.firstSnapshot == nil, !snapshot.content.isEmpty {
                        measurements.firstSnapshot = measurements.elapsed
                        measurements.report("first_model_snapshot", at: measurements.firstSnapshot)
                    }
                    measurements.response = snapshot.content
                    receive(snapshot.content)
                }
                measurements.textComplete = measurements.elapsed
                measurements.report("text_complete", at: measurements.textComplete)
                textFinished.fulfill()
            } speak: { phrases in
                let observed = AsyncThrowingStream<String, Error>.makeStream()
                defer { observed.continuation.finish() }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await Self.forward(
                            phrases, to: observed.continuation, measurements: measurements
                        )
                    }
                    group.addTask {
                        try await speak(observed.stream) { samples, rate in
                            try Task.checkCancellation()
                            try await player.enqueue(samples, sampleRate: rate)
                            guard !samples.isEmpty else { return }
                            if measurements.firstPCM == nil {
                                measurements.firstPCM = measurements.elapsed
                                measurements.report("first_pcm_scheduled", at: measurements.firstPCM)
                            }
                            // Count an actually scheduled buffer containing speech,
                            // rather than an empty or entirely silent initial chunk.
                            if measurements.firstNonSilentPCM == nil,
                               samples.contains(where: { abs($0) > 0.001 }) {
                                measurements.firstNonSilentPCM = measurements.elapsed
                                measurements.report("first_non_silent_pcm_scheduled", at: measurements.firstNonSilentPCM)
                                audibleBuffer.fulfill()
                            }
                        }
                    }
                    do {
                        while try await group.next() != nil { }
                    } catch {
                        group.cancelAll()
                        observed.continuation.finish(throwing: error)
                        throw error
                    }
                }
            }
        }
        defer { operation.cancel() }

        let result = await XCTWaiter.fulfillment(of: [textFinished, audibleBuffer], timeout: 90)
        // Both observations are now recorded. Avoid synthesizing the remaining
        // answer just to measure startup; never delay the source to force overlap.
        operation.cancel()
        switch await operation.result {
        case .success: break
        case .failure(let error):
            if !(error is CancellationError) { throw error }
        }
        XCTAssertEqual(result, .completed, "The model and voice must both produce output on the device.")
        let firstAudio = try XCTUnwrap(measurements.firstNonSilentPCM)
        let textComplete = try XCTUnwrap(measurements.textComplete)
        print("\(prefix) response=\(measurements.response)")
        XCTAssertLessThan(
            firstAudio, textComplete,
            "Audible PCM must be queued before real text generation completes; audio=\(firstAudio)s, text=\(textComplete)s."
        )
    }

    @MainActor
    private static func forward(
        _ phrases: AsyncThrowingStream<String, Error>,
        to continuation: AsyncThrowingStream<String, Error>.Continuation,
        measurements: Measurements
    ) async throws {
        do {
            for try await phrase in phrases {
                try Task.checkCancellation()
                if measurements.firstPhrase == nil {
                    measurements.firstPhrase = measurements.elapsed
                    measurements.report("first_voice_phrase", at: measurements.firstPhrase)
                    print("\(measurements.prefix) first_phrase=\(phrase)")
                }
                continuation.yield(phrase)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }

    @MainActor
    private final class Measurements {
        private let started = ProcessInfo.processInfo.systemUptime
        let prefix: String
        var firstSnapshot: TimeInterval?
        var firstPhrase: TimeInterval?
        var firstPCM: TimeInterval?
        var firstNonSilentPCM: TimeInterval?
        var textComplete: TimeInterval?
        var response = ""

        init(prefix: String) { self.prefix = prefix }

        var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - started }

        func report(_ event: String, at time: TimeInterval?) {
            guard let time else { return }
            print("\(prefix) \(event)=\(String(format: "%.3f", time))s")
        }
    }
}
