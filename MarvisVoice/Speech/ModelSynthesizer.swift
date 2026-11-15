import Foundation
import KokoroTTS
import MLX
@preconcurrency import MLXAudioTTS

/// Speaks with a downloaded speech model. A single owner serializes access to the
/// mutable model and codec caches.
actor ModelSynthesizer {
    /// Timing for one utterance, measured on the generation side.
    struct Report: Sendable {
        var engine: Speaker.Engine
        var audioSeconds = 0.0
        var processingSeconds = 0.0
        var firstAudioSeconds: Double?
        var chunks = 0
        var loadSeconds: Double?
        var reloadedAfterInterruption = false
        /// The most GPU memory the models have held at once since the app launched, in bytes.
        var peakModelMemory = 0
        private let started = ContinuousClock.now

        mutating func record(_ samples: [Float], sampleRate: Int, processingSeconds: Double) {
            chunks += 1
            audioSeconds += Double(samples.count) / Double(sampleRate)
            self.processingSeconds += processingSeconds
            if firstAudioSeconds == nil {
                firstAudioSeconds = (ContinuousClock.now - started).totalSeconds
            }
        }
    }

    /// Marvis streams through its dedicated API, and other mlx-audio-swift models through
    /// the package's generic one. Kokoro on Core ML comes from its own package, and its
    /// 8-bit version and Supertonic from FluidAudio.
    private enum Model {
        case marvis(MarvisTTSModel)
        case generic(any SpeechGenerationModel)
        case coreML(KokoroTTS)
        case piecewise(any PiecewiseVoice)
    }

    /// The models are large; every caller in the process shares one loaded copy of one engine.
    static let shared = ModelSynthesizer()
    private var loaded: (engine: Speaker.Engine, model: Model)?
    private var busy = false
    private var droppedAfterInterruption = false

    func prepare(_ engine: Speaker.Engine, voice: Speaker.Voice? = nil) async throws {
        guard !busy else { throw SpeechError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer { finish() }
        _ = try await load(engine)
        let voice = voice ?? engine.voices[0]
        switch loaded?.model {
        case .marvis(let model):
            try model.prepare(voice: Self.marvisVoice(voice))
        case .generic(let model):
            // The first synthesis reads the model's pronunciation data and warms the
            // GPU. Spend that here instead of at the start of the first reply.
            for try await _ in model.generateSamplesStream(
                text: "Ready.", voice: voice.id, refAudio: nil, refText: nil, language: nil
            ) {}
            try Task.checkCancellation()
        case .coreML(let model):
            // Compiles the Core ML models for this device, which is slow the first time,
            // and runs one real synthesis so the first reply does not pay for either.
            do {
                try await model.prewarm(voice: KokoroVoiceID(voice.id))
            } catch {
                try Task.checkCancellation()
                throw error
            }
        case .piecewise(let model):
            // The first synthesis is slow while Core ML prepares the models for this device.
            _ = try await model.synthesize("Ready.", voice: voice.id)
            try Task.checkCancellation()
        case nil:
            break
        }
    }

    /// Returns how long loading took, or nil when this engine's model was already in memory.
    private func load(_ engine: Speaker.Engine) async throws -> Double? {
        guard loaded?.engine != engine else { return nil }
        // MLX keeps freed GPU buffers for reuse, by default up to most of the device's
        // memory, and iOS closes an app long before that. Of the engines here, only
        // Marvis's loader sets this cap itself.
        Memory.cacheLimit = 100 * 1024 * 1024
        // Only one engine stays in memory. Release the other before its replacement loads.
        loaded = nil
        let start = ContinuousClock.now
        let model: Model
        switch engine {
        case .system:
            throw SpeechError.message("The iPhone voice has no model to load.")
        case .marvis:
            model = .marvis(try await MarvisTTSModel.fromPretrained(engine.assets[0].repo))
        case .kokoro:
            // The English processor is set up once, here. The package's multilingual one
            // contacts Hugging Face again for every sentence it speaks.
            model = .generic(try await KokoroModel.fromPretrained(
                engine.assets[0].repo, textProcessor: MisakiTextProcessor()
            ))
        case .kokoroCoreML:
            // Loads straight from the files `ModelStore` downloaded. The package's own
            // Hugging Face entry point contacts the network and re-hashes every file on
            // each call, and uses this same folder for its compiled models.
            let directory = engine.assets[0].directory
            model = .coreML(try await KokoroTTS.load(resources: .downloadedDirectory(
                root: directory,
                compiledModelsDirectory: directory.appendingPathComponent("compiled-v2", isDirectory: true)
            )))
        case .kokoroInt8:
            let voice = KokoroInt8Voice()
            try await voice.load()
            model = .piecewise(voice)
        case .supertonic(let version):
            let voice = SupertonicVoice(version: version)
            try await voice.load()
            model = .piecewise(voice)
        }
        try Task.checkCancellation()
        loaded = (engine, model)
        droppedAfterInterruption = false
        return (ContinuousClock.now - start).totalSeconds
    }

    private func finish() {
        busy = false
        guard Task.isCancelled else { return }
        switch loaded?.model {
        case .coreML, .piecewise:
            // Core ML synthesis runs inside the awaited call, so the model is safe to keep.
            break
        case .marvis, .generic, nil:
            // Upstream MLX generation owns an unstructured task. After cancellation,
            // never reuse that instance while its last GPU operation unwinds.
            loaded = nil
            droppedAfterInterruption = true
        }
    }

    @discardableResult
    func speak(_ phrases: AsyncThrowingStream<String, Error>,
               engine: Speaker.Engine, voice: Speaker.Voice? = nil,
               receive: @MainActor @Sendable ([Float], Int) async throws -> Void) async throws -> Report {
        guard !busy else { throw SpeechError.message("The voice engine is still busy. Try again shortly.") }
        busy = true
        defer { finish() }
        var report = Report(engine: engine, reloadedAfterInterruption: droppedAfterInterruption)
        report.loadSeconds = try await load(engine)
        guard let model = loaded?.model else {
            throw SpeechError.message("\(engine.rawValue) could not be loaded.")
        }
        let voice = voice ?? engine.voices[0]
        for try await phrase in phrases {
            switch model {
            case .marvis(let model):
                for piece in SpeechText.chunks(phrase) {
                    try Task.checkCancellation()
                    let stream = model.generate(
                        text: piece,
                        voice: Self.marvisVoice(voice),
                        qualityLevel: .maximum,
                        // One 80 ms codec frame: deliver the first playable audio
                        // immediately instead of waiting for six frames to accumulate.
                        streamingInterval: 0.08
                    )
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        report.record(chunk.audio, sampleRate: chunk.sampleRate,
                                      processingSeconds: chunk.processingTime)
                        try await receive(chunk.audio, chunk.sampleRate)
                    }
                }
            case .generic(let model):
                // These models return each piece whole and pause after it, so a piece is a
                // sentence. A longer sentence is cut only to bound memory: Kokoro needs about
                // 250 MB per second of speech while it generates a piece, and 110 characters
                // is about 7 seconds.
                let pieces = StreamingSpeechText.sentences(in: phrase).flatMap { SpeechText.chunks($0, limit: 110) }
                for piece in pieces {
                    try Task.checkCancellation()
                    // They report no timing of their own, so time the wait for audio.
                    let started = ContinuousClock.now
                    var samples: [Float] = []
                    for try await chunk in model.generateSamplesStream(
                        text: engine == .kokoro ? SpeechText.joiningHyphenatedWords(piece) : piece,
                        voice: voice.id, refAudio: nil, refText: nil, language: nil
                    ) {
                        try Task.checkCancellation()
                        samples += chunk
                    }
                    samples = SpeechAudio.trimmingSilence(samples, sampleRate: model.sampleRate)
                    report.record(samples, sampleRate: model.sampleRate,
                                  processingSeconds: (ContinuousClock.now - started).totalSeconds)
                    try await receive(samples, model.sampleRate)
                }
            case .coreML(let model):
                // One sentence per call; the package splits a very long one itself.
                for piece in StreamingSpeechText.sentences(in: phrase) {
                    try Task.checkCancellation()
                    let started = ContinuousClock.now
                    let audio: KokoroAudio
                    do {
                        audio = try await model.synthesize(
                            SpeechText.joiningHyphenatedWords(piece), voice: KokoroVoiceID(voice.id)
                        )
                    } catch KokoroError.emptyText, KokoroError.emptyPhonemizerOutput, KokoroError.inaudibleChunk {
                        // Nothing in this piece can be spoken, such as a lone dash.
                        continue
                    } catch {
                        // The package reports cancellation as an error of its own.
                        try Task.checkCancellation()
                        throw error
                    }
                    let samples = SpeechAudio.trimmingSilence(audio.samples, sampleRate: audio.sampleRate)
                    report.record(samples, sampleRate: audio.sampleRate,
                                  processingSeconds: (ContinuousClock.now - started).totalSeconds)
                    try await receive(samples, audio.sampleRate)
                }
            case .piecewise(let model):
                // These models put up to half a second of silence on each side of what they
                // speak. Supertonic takes about 70 characters at a time, and FluidAudio would
                // cut a longer sentence itself and keep that silence, heard as a pause of
                // over a second in mid-sentence. So the sentence is cut here, and each piece
                // keeps only the pause its ending calls for: a sentence's, a comma's, or
                // next to none. Kokoro's limit is far longer, so most sentences stay whole.
                let sampleRate = type(of: model).sampleRate
                for sentence in StreamingSpeechText.sentences(in: phrase) {
                    // Kokoro speaks a piece with nothing to pronounce, such as a lone dash,
                    // as a short noise.
                    let pieces = SpeechText.clauses(sentence, limit: type(of: model).pieceLength)
                        .filter { $0.contains { $0.isLetter || $0.isNumber } }
                    for (index, piece) in pieces.enumerated() {
                        try Task.checkCancellation()
                        let started = ContinuousClock.now
                        let trail = index == pieces.count - 1 ? 0.3 : ",;:—".contains(piece.last ?? " ") ? 0.25 : 0.1
                        let samples = SpeechAudio.trimmingSilence(
                            try await model.synthesize(piece, voice: voice.id),
                            sampleRate: sampleRate, trail: trail
                        )
                        report.record(samples, sampleRate: sampleRate,
                                      processingSeconds: (ContinuousClock.now - started).totalSeconds)
                        try await receive(samples, sampleRate)
                    }
                }
            }
        }
        try Task.checkCancellation()
        report.peakModelMemory = Memory.peakMemory
        return report
    }

    private static func marvisVoice(_ voice: Speaker.Voice) -> MarvisTTSModel.Voice {
        MarvisTTSModel.Voice(rawValue: voice.id) ?? .conversationalA
    }
}

/// A model that speaks one piece of text per call, whole, and limits how long a piece can be.
protocol PiecewiseVoice: Sendable {
    static var sampleRate: Int { get }
    /// The most characters the model is given at once.
    static var pieceLength: Int { get }
    func synthesize(_ text: String, voice: String) async throws -> [Float]
}

enum SpeechAudio {
    /// Shortens the silence around a piece of speech. Kokoro pads each piece with about
    /// 0.3 s before and 0.5 s after, which is heard as a long gap between sentences that
    /// are spoken one after another.
    static func trimmingSilence(_ samples: [Float], sampleRate: Int,
                                lead: Double = 0.05, trail: Double = 0.3) -> [Float] {
        let quiet: Float = 0.01
        guard let first = samples.firstIndex(where: { abs($0) > quiet }),
              let last = samples.lastIndex(where: { abs($0) > quiet }) else { return samples }
        let start = max(0, first - Int(lead * Double(sampleRate)))
        let end = min(samples.count, last + 1 + Int(trail * Double(sampleRate)))
        return Array(samples[start..<end])
    }
}

private extension Duration {
    var totalSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
