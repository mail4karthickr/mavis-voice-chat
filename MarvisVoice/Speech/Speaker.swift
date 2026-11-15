import Foundation
import FoundationModels
import Observation
import os

/// On-device speech for text and for replies that are still being written.
///
/// Drop the `Speech` folder into an iOS 26 app target that links the `MLXAudioTTS`
/// product of mlx-audio-swift, `KokoroTTS` of kokoro-coreml, and `FluidAudio`.
///
///     let speaker = Speaker()
///     try await speaker.speak("Hello there.")
///
///     let session = LanguageModelSession()
///     try await speaker.speak(session.streamResponse(to: "Tell me a fun fact")) { text in
///         reply = text   // the reply so far, for display
///     }
///
/// Each `speak` call returns after the last sample has played. Starting a new one,
/// calling `stop()`, or cancelling the calling task interrupts the current speech.
/// The iPhone voice speaks at once. The other engines need their model on the device
/// first; `ModelStore` downloads it.
@MainActor @Observable
final class Speaker {
    /// What turns text into audio. Text splitting, playback and diagnostics are
    /// shared, so engines can be compared on the same device.
    enum Engine: Hashable, Sendable, CaseIterable, Identifiable {
        /// An installed iPhone voice. Nothing to download.
        case system
        /// Expressive conversational speech, generated 80 ms at a time.
        case marvis
        /// Clear read-aloud speech, generated a sentence at a time on the GPU.
        case kokoro
        /// The same Kokoro model converted to Core ML, running mostly on the Neural Engine.
        case kokoroCoreML
        /// Kokoro on Core ML with 8-bit weights, through FluidAudio. The smallest Kokoro,
        /// at under half the download of `kokoroCoreML`.
        case kokoroInt8
        /// Supertonic 3 on Core ML, through FluidAudio. 44.1 kHz, ten voices. Each
        /// version is a separate download, so that size can be weighed against sound.
        case supertonic(SupertonicVoice.Version)

        static var allCases: [Engine] {
            [.system, .marvis, .kokoro, .kokoroCoreML, .kokoroInt8]
                + SupertonicVoice.Version.allCases.map(Engine.supertonic)
        }

        /// The engine's name as shown, which is also how a selection is stored.
        var rawValue: String {
            switch self {
            case .system: "iPhone"
            case .marvis: "Marvis"
            case .kokoro: "Kokoro"
            case .kokoroCoreML: "Kokoro Core ML"
            case .kokoroInt8: "Kokoro Core ML · int8"
            case .supertonic(let version): "Supertonic 3 · \(version.rawValue)"
            }
        }

        init?(rawValue: String) {
            guard let engine = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = engine
        }

        var id: String { rawValue }

        /// The Hugging Face repositories the engine loads, its model first. Empty for the iPhone voice.
        var assets: [ModelAsset] {
            switch self {
            case .system:
                []
            case .marvis:
                [
                    ModelAsset(repo: "Marvis-AI/marvis-tts-250m-v0.2-MLX-8bit", megabytes: 672),
                    // The audio codec is one file in a repository that also holds a far larger model.
                    ModelAsset(repo: "kyutai/moshiko-pytorch-bf16",
                               kind: .mlxAudio(files: ["tokenizer-e351c8d8-checkpoint125.safetensors"]), megabytes: 385),
                ]
            case .kokoro:
                [
                    ModelAsset(repo: "mlx-community/Kokoro-82M-bf16", megabytes: 361),
                    // English pronunciation data.
                    ModelAsset(repo: "beshkenadze/kitten-tts-g2p", megabytes: 9),
                ]
            case .kokoroCoreML:
                [ModelAsset(repo: "mattmireles/kokoro-coreml", kind: .kokoroCoreML, megabytes: 218)]
            case .kokoroInt8:
                [ModelAsset(repo: "FluidInference/kokoro-82m-coreml", kind: .kokoroInt8(voices: voices.map(\.id)),
                            megabytes: 96)]
            case .supertonic(let version):
                [ModelAsset(repo: "FluidInference/supertonic-3-coreml", kind: .supertonic(version),
                            megabytes: version.megabytes)]
            }
        }

        /// The first voice is the engine's default.
        var voices: [Voice] {
            switch self {
            case .system:
                // The best installed English voice is chosen when speaking.
                [Voice(id: "system", name: "Default")]
            case .marvis:
                [
                    Voice(id: "conversational_a", name: "Conversational A"),
                    Voice(id: "conversational_b", name: "Conversational B"),
                ]
            case .kokoro, .kokoroInt8:
                // American voices only: both packages' English pronunciation data is American.
                [
                    Voice(id: "af_heart", name: "Heart · female"),
                    Voice(id: "af_bella", name: "Bella · female"),
                    Voice(id: "am_michael", name: "Michael · male"),
                    Voice(id: "am_fenrir", name: "Fenrir · male"),
                ]
            case .kokoroCoreML:
                // The bundle its package hosts carries this one voice.
                [Voice(id: "af_heart", name: "Heart · female")]
            case .supertonic:
                (1...5).map { Voice(id: "F\($0)", name: "F\($0) · female") }
                    + (1...5).map { Voice(id: "M\($0)", name: "M\($0) · male") }
            }
        }

        /// How a reply that is still being written is cut into phrases for this engine.
        var phraseStyle: StreamingSpeechText.Style {
            switch self {
            case .system: .immediate
            case .marvis: .natural
            // These speak each piece as a separate utterance, with a pause after it.
            case .kokoro, .kokoroCoreML, .kokoroInt8, .supertonic: .sentences
            }
        }
    }

    /// A voice, identified by the name its engine's model uses.
    struct Voice: Hashable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    /// How each element of a text stream relates to the previous one.
    enum StreamFormat: Sendable {
        /// Each element is the whole reply so far, as Foundation Models snapshots are.
        case cumulative
        /// Each element is new text to append, such as token deltas.
        case incremental
    }

    /// Changing the engine selects its default voice. A model loads on the next `prepare` or `speak`.
    var engine: Engine {
        didSet { if engine != oldValue { voice = engine.voices[0] } }
    }
    var voice: Voice
    /// True once the current engine can speak without loading a model first.
    var isPrepared: Bool { engine == .system || preparedEngine == engine }
    private var preparedEngine: Engine?
    private(set) var isSpeaking = false
    /// Timing and audio-session details for the most recent utterance, for diagnosing playback problems.
    /// Also logged under subsystem "Speaker" (filter the Xcode console or Console.app by "Speaker").
    private(set) var lastReport: String?
    /// Called once per `speak` when its first audio reaches the speaker.
    @ObservationIgnored var onPlaybackStart: (@MainActor () -> Void)?

    @ObservationIgnored private let synthesizer = ModelSynthesizer.shared
    @ObservationIgnored private let systemVoice = SystemVoiceSynthesizer()
    @ObservationIgnored private let player = PCMPlayer()
    @ObservationIgnored private var current: Task<Void, Error>?
    @ObservationIgnored private var currentID = UUID()
    @ObservationIgnored private var playbackStarted = false
    @ObservationIgnored private var synthesisReport: ModelSynthesizer.Report?
    private static let log = Logger(subsystem: "Speaker", category: "voice")
    @ObservationIgnored private var playback: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

    init(engine: Engine = .system, voice: Voice? = nil) {
        self.engine = engine
        self.voice = voice ?? engine.voices[0]
    }

    /// Loads the engine's model into memory, downloading anything still missing. Optional,
    /// since `speak` loads on demand, but calling it early keeps loading out of the first reply.
    func prepare() async throws {
        let engine = engine
        guard engine != .system else { return }
        try await synthesizer.prepare(engine, voice: voice)
        preparedEngine = engine
    }

    /// Speaks a complete piece of text.
    func speak(_ text: String) async throws {
        try await perform {
            let (phrases, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            continuation.yield(text)
            continuation.finish()
            try await self.synthesize(phrases)
        }
    }

    /// Speaks a streamed reply while it is still being generated.
    /// `onText` receives the full reply so far each time the stream advances.
    func speak<Text: AsyncSequence>(
        _ stream: Text,
        format: StreamFormat = .cumulative,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws where Text.Element == String {
        try await perform {
            try await StreamingReply.run(
                style: self.engine.phraseStyle,
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
    func speak(
        _ response: LanguageModelSession.ResponseStream<String>,
        onText: (@MainActor (String) -> Void)? = nil
    ) async throws {
        try await speak(response.map { $0.content }, format: .cumulative, onText: onText)
    }

    /// Stops generation and playback immediately. The interrupted `speak` throws `CancellationError`.
    func stop() {
        current?.cancel()
        systemVoice.stop()
        player.stop()
        if let playback {
            self.playback = nil
            playback.continuation.resume(throwing: CancellationError())
        }
        isSpeaking = false
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) async throws {
        // One utterance is synthesized at a time, so let the previous one unwind first.
        while let previous = current {
            stop()
            _ = await previous.result
        }
        try Task.checkCancellation()
        let id = UUID()
        currentID = id
        isSpeaking = true
        playbackStarted = false
        synthesisReport = nil
        let task = Task {
            defer {
                if self.currentID == id {
                    self.current = nil
                    self.isSpeaking = false
                    self.recordReport()
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
        let engine = engine
        let receive: @MainActor @Sendable ([Float], Int) async throws -> Void = { samples, rate in
            try await self.player.enqueue(samples, sampleRate: rate)
            if !self.playbackStarted {
                self.playbackStarted = true
                self.onPlaybackStart?()
            }
        }
        if engine == .system {
            try await systemVoice.speak(phrases, receive: receive)
        } else {
            synthesisReport = try await synthesizer.speak(phrases, engine: engine, voice: voice, receive: receive)
            preparedEngine = engine
        }
    }

    private func recordReport() {
        let playback = player.report
        var parts = ["\(engine.rawValue) voice"]
        if let synthesis = synthesisReport {
            let ratio = synthesis.audioSeconds > 0 ? synthesis.processingSeconds / synthesis.audioSeconds : 0
            parts = [
                synthesis.engine.rawValue + String(
                    format: " synthesis: %.1f s of audio in %.1f s (%.2f× real time), first audio after %.2f s, %d chunks",
                    synthesis.audioSeconds, synthesis.processingSeconds, ratio, synthesis.firstAudioSeconds ?? 0, synthesis.chunks)
            ]
        }
        parts += [
            "playback: \(playback.buffers) buffers, \(playback.underruns) underruns, \(playback.configurationChanges) session changes",
            "session: \(playback.session.isEmpty ? "never started" : playback.session)",
        ]
        if let load = synthesisReport?.loadSeconds { parts.append(String(format: "model loaded in %.1f s", load)) }
        if synthesisReport?.reloadedAfterInterruption == true { parts.append("reloaded after an interrupted utterance") }
        if let footprint = Self.memoryFootprint { parts.append("app memory \(footprint / 1_048_576) MB") }
        if let peak = synthesisReport?.peakModelMemory, peak > 0 { parts.append("model peak \(peak / 1_048_576) MB") }
        let report = parts.joined(separator: " · ")
        lastReport = report
        Self.log.info("\(report, privacy: .public)")
    }

    /// The figure iOS compares with its per-app limit before it closes an app for using too much memory.
    private static var memoryFootprint: UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
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
