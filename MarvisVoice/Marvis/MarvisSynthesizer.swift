import Foundation
@preconcurrency import MLXAudioTTS

/// A single owner serializes access to the mutable Marvis model and codec caches.
actor MarvisSynthesizer {
    /// The model and codec are large; every caller in the process shares one loaded copy.
    static let shared = MarvisSynthesizer()
    static let modelID = "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit"
    private var model: MarvisTTSModel?
    private var busy = false

    func prepare(voiceB: Bool = false) async throws {
        guard !busy else { throw MarvisError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer { busy = false }
        try await load()
        try model?.prepare(voice: voiceB ? .conversationalB : .conversationalA)
    }

    private func load() async throws {
        if model == nil {
            let loaded = try await MarvisTTSModel.fromPretrained(Self.modelID)
            try Task.checkCancellation()
            model = loaded
        }
    }

    func speak(_ phrases: AsyncThrowingStream<String, Error>, voiceB: Bool,
               receive: @MainActor @Sendable ([Float], Int) async throws -> Void) async throws {
        guard !busy else { throw MarvisError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer {
            busy = false
            // Upstream generation owns an unstructured task. After cancellation,
            // never reuse that instance while its last GPU operation unwinds.
            if Task.isCancelled { model = nil }
        }
        try await load()
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
                    try await receive(chunk.audio, chunk.sampleRate)
                }
            }
        }
        try Task.checkCancellation()
    }
}
