import XCTest
@testable import MarvisVoice

final class SpeakerTests: XCTestCase {
    /// The iPhone voice needs no model, so the whole path from streamed text to playback runs anywhere.
    @MainActor
    func testSpeaksAStreamedReplyWithTheSystemVoice() async throws {
        let speaker = Speaker()
        defer { speaker.stop() }
        XCTAssertEqual(speaker.engine, .system)
        XCTAssertTrue(speaker.isPrepared)

        let observed = Observed()
        speaker.onPlaybackStart = { observed.playbackStarted = true }
        let (snapshots, continuation) = AsyncStream<String>.makeStream()
        let speaking = Task { @MainActor in
            try await speaker.speak(snapshots) { observed.text = $0 }
        }
        continuation.yield("Hello there.")
        continuation.yield("Hello there. This reply arrives in two parts.")
        continuation.finish()
        try await speaking.value

        XCTAssertTrue(observed.playbackStarted)
        XCTAssertEqual(observed.text, "Hello there. This reply arrives in two parts.")
        XCTAssertFalse(speaker.isSpeaking)
        let report = try XCTUnwrap(speaker.lastReport)
        XCTAssertTrue(report.hasPrefix("iPhone voice"), report)
        XCTAssertFalse(report.contains("playback: 0 buffers"), report)
        XCTAssertTrue(report.contains("app memory"), report)
    }

    @MainActor
    func testChangingTheEngineSelectsItsDefaultVoice() {
        let speaker = Speaker()
        speaker.engine = .kokoro
        XCTAssertEqual(speaker.voice, Speaker.Engine.kokoro.voices[0])
        XCTAssertFalse(speaker.isPrepared, "A model must be loaded before it counts as prepared")
        speaker.engine = .system
        XCTAssertTrue(speaker.isPrepared)
    }

    /// A selection is stored by name, and each version of a model is an engine of its own.
    func testEveryEngineHasItsOwnNameThatLeadsBackToIt() {
        let engines = Speaker.Engine.allCases
        XCTAssertEqual(Set(engines.map(\.rawValue)).count, engines.count)
        for engine in engines {
            XCTAssertEqual(Speaker.Engine(rawValue: engine.rawValue), engine)
        }
        XCTAssertEqual(Speaker.Engine(rawValue: "Supertonic 3 · int8"), .supertonic(.int8))
        XCTAssertNil(Speaker.Engine(rawValue: "Supertonic 3"))
    }

    /// A version whose name FluidAudio does not know would quietly load the unquantized files.
    func testSupertonicVersionsDifferInOneStageAndShareTheRest() {
        let files = SupertonicVoice.Version.allCases.map { Set(SupertonicVoice.files($0).map(\.lastPathComponent)) }
        let shared = files.dropFirst().reduce(files[0]) { $0.intersection($1) }
        // Three stages, two JSON files and ten voice styles.
        XCTAssertEqual(shared.count, 15, "\(shared.sorted())")
        let own = files.map { $0.subtracting(shared) }
        XCTAssertEqual(own.map(\.count), [1, 1, 3, 1], "\(own)")
        XCTAssertEqual(Set(own.flatMap { $0 }).count, 6, "\(own)")
    }

    /// The engine counts as downloaded only once every one of these exists, so each has
    /// to be a file that FluidAudio writes. The names are those a download left on disk.
    func testKokoroInt8NeedsItsStagesItsVoicesAndThePronunciationData() {
        let files = KokoroInt8Voice.files(voices: ["af_heart", "am_michael"])
        let folders = Dictionary(grouping: files) { $0.deletingLastPathComponent().lastPathComponent }
            .mapValues { Set($0.map(\.lastPathComponent)) }
        XCTAssertEqual(folders["ANE"], [
            "KokoroAlbert.mlmodelc", "KokoroPostAlbert.mlmodelc", "KokoroAlignment.mlmodelc",
            "KokoroProsody_v2.mlmodelc", "KokoroNoise_v2.mlmodelc", "KokoroVocoder.mlmodelc",
            "KokoroTail_v2.mlmodelc", "vocab.json", "af_heart.bin", "am_michael.bin",
        ])
        XCTAssertEqual(folders["kokoro"], [
            "G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc", "g2p_vocab.json", "us_lexicon_cache.json",
        ])
    }

    @MainActor
    private final class Observed {
        var playbackStarted = false
        var text = ""
    }
}
