import Foundation
@preconcurrency import MLXAudioTTS

/// A single owner serializes access to the mutable Marvis model and codec caches.
actor MarvisSynthesizer {
    /// Timing for one utterance, measured on the generation side.
    struct Report: Sendable {
        var audioSeconds = 0.0
        var processingSeconds = 0.0
        var firstAudioSeconds: Double?
        var chunks = 0
        var loadSeconds: Double?
        var reloadedAfterInterruption = false
    }

    /// The model and codec are large; every caller in the process shares one loaded copy.
    static let shared = MarvisSynthesizer()
    static let modelID = "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"
    private var model: MarvisTTSModel?
    private var busy = false
    private var droppedAfterInterruption = false

    func prepare(voiceB: Bool = false) async throws {
        guard !busy else { throw MarvisError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer { busy = false }
        _ = try await load()
        try model?.prepare(voice: voiceB ? .conversationalB : .conversationalA)
    }

    /// Returns how long loading took, or nil when the model was already in memory.
    private func load() async throws -> Double? {
        guard model == nil else { return nil }
        let start = ContinuousClock.now
        let loaded = try await MarvisTTSModel.fromPretrained(Self.modelID)
        try Task.checkCancellation()
        model = loaded
        droppedAfterInterruption = false
        return (ContinuousClock.now - start).totalSeconds
    }

    @discardableResult
    func speak(_ phrases: AsyncThrowingStream<String, Error>, voiceB: Bool,
               receive: @MainActor @Sendable ([Float], Int) async throws -> Void) async throws -> Report {
        guard !busy else { throw MarvisError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer {
            busy = false
            // Upstream generation owns an unstructured task. After cancellation,
            // never reuse that instance while its last GPU operation unwinds.
            if Task.isCancelled {
                model = nil
                droppedAfterInterruption = true
            }
        }
        var report = Report(reloadedAfterInterruption: droppedAfterInterruption)
        let start = ContinuousClock.now
        report.loadSeconds = try await load()
        guard let model else { throw MarvisError.message("Marvis could not be loaded.") }
        for try await phrase in phrases {
            for piece in MarvisSpeechText.chunks(phrase) {
                try Task.checkCancellation()
                let stream = model.generate(
                    text: piece,
                    voice: voiceB ? .conversationalB : .conversationalA,
                    qualityLevel: .maximum,
                    // One 80 ms codec frame: deliver the first playable audio
                    // immediately instead of waiting for six frames to accumulate.
                    streamingInterval: 0.08
                )
                for try await chunk in stream {
                    try Task.checkCancellation()
                    report.chunks += 1
                    report.audioSeconds += chunk.audioDuration
                    report.processingSeconds += chunk.processingTime
                    if report.firstAudioSeconds == nil {
                        report.firstAudioSeconds = (ContinuousClock.now - start).totalSeconds
                    }
                    try await receive(chunk.audio, chunk.sampleRate)
                }
            }
        }
        try Task.checkCancellation()
        return report
    }
}

private extension Duration {
    var totalSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
