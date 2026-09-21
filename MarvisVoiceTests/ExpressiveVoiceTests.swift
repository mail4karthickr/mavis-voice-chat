import AVFoundation
import Speech
import XCTest
@preconcurrency import MLXAudioTTS
@testable import MarvisVoice

final class ExpressiveVoiceTests: XCTestCase {
    /// Compare sustained synthesis, not just startup. The saved audio and local
    /// transcription expose artifacts independently of the playback queue.
    @MainActor
    func testExpressiveVoiceStreamingDiagnostics() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Expressive voice diagnostics require Metal on an iPhone.")
        #else
        let finished = expectation(description: "Both expressive voice configurations finish")
        let operation = Task { @MainActor in
            defer { finished.fulfill() }
            let loadStarted = ProcessInfo.processInfo.systemUptime
            let model = try await MarvisTTSModel.fromPretrained(VoiceSynthesizer.modelID)
            try Task.checkCancellation()
            print("EXPRESSIVE_DIAGNOSTIC model_load_seconds=\(Self.number(ProcessInfo.processInfo.systemUptime - loadStarted))")

            for (quality, label) in [
                (MarvisTTSModel.QualityLevel.maximum, "codebooks_32"),
                (.maximum, "codebooks_32_cached"),
                (.medium, "codebooks_16")
            ] {
                try Task.checkCancellation()
                try await self.measure(model, quality: quality, label: label)
            }
        }
        defer { operation.cancel() }

        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 180)
        guard result == .completed else {
            operation.cancel()
            XCTFail("Expressive voice diagnostics exceeded the 180-second limit.")
            return
        }
        try await operation.value
        #endif
    }

    @MainActor
    private func measure(_ model: MarvisTTSModel, quality: MarvisTTSModel.QualityLevel, label: String) async throws {
        let phrase = "The red balloon is next to the blue chair. Please put it on the table."
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [Float] = []
        var sampleRate = 0
        var chunkCount = 0
        var firstPCM: TimeInterval?
        var firstNonSilentPCM: TimeInterval?
        var previousArrival: TimeInterval?
        var maximumGap: TimeInterval = 0
        var minimumStartupBuffer: TimeInterval = 0

        for try await chunk in model.generate(
            text: phrase, voice: .conversationalA,
            qualityLevel: quality, streamingInterval: 0.08
        ) {
            try Task.checkCancellation()
            guard !chunk.audio.isEmpty else { continue }
            let arrival = ProcessInfo.processInfo.systemUptime - started
            XCTAssertGreaterThan(chunk.sampleRate, 0)
            if sampleRate != 0 { XCTAssertEqual(chunk.sampleRate, sampleRate) }
            sampleRate = chunk.sampleRate
            if let previousArrival { maximumGap = max(maximumGap, arrival - previousArrival) }
            previousArrival = arrival
            if firstPCM == nil { firstPCM = arrival }
            if firstNonSilentPCM == nil, chunk.audio.contains(where: { abs($0) > 0.001 }) {
                firstNonSilentPCM = arrival
            }
            // The buffer needed to play continuously if playback starts when
            // the first chunk arrives, ignoring playback scheduling overhead.
            let deliveredDuration = Double(samples.count) / Double(chunk.sampleRate)
            minimumStartupBuffer = max(minimumStartupBuffer, arrival - (firstPCM ?? arrival) - deliveredDuration)
            samples.append(contentsOf: chunk.audio)
            chunkCount += 1
        }
        try Task.checkCancellation()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertFalse(samples.isEmpty, "Marvis produced no audio for \(label)")
        XCTAssertTrue(samples.allSatisfy(\.isFinite), "Marvis produced invalid PCM for \(label)")
        XCTAssertNotNil(firstNonSilentPCM, "Marvis produced only silence for \(label)")
        guard sampleRate > 0, !samples.isEmpty else { return }
        let duration = Double(samples.count) / Double(sampleRate)
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        print("EXPRESSIVE_DIAGNOSTIC \(label) first_pcm_seconds=\(Self.number(firstPCM ?? -1)) first_speech_seconds=\(Self.number(firstNonSilentPCM ?? -1)) generation_seconds=\(Self.number(elapsed)) audio_seconds=\(Self.number(duration)) real_time_factor=\(Self.number(elapsed / duration)) max_chunk_gap_seconds=\(Self.number(maximumGap)) minimum_startup_buffer_seconds=\(Self.number(minimumStartupBuffer)) chunks=\(chunkCount) sample_rate=\(sampleRate) rms=\(Self.number(rms))")

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("expressive-diagnostic-\(label).wav")
        try Self.save(samples, sampleRate: sampleRate, to: url)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = "Expressive voice \(label)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("EXPRESSIVE_DIAGNOSTIC \(label) waveform=\(url.path) expected=\(phrase)")
        await transcribe(url, expected: phrase, label: label)
    }

    private static func save(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = buffer.frameCapacity
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor
    private func transcribe(_ url: URL, expected: String, label: String) async {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            print("EXPRESSIVE_DIAGNOSTIC \(label) transcription_unavailable=true")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let recognized = expectation(description: "Recognize saved expressive voice \(label)")
        let state = Transcription()
        let recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard !state.finished, final || failure != nil else { return }
                state.finished = true
                state.text = text ?? ""
                state.error = failure
                recognized.fulfill()
            }
        }
        defer { state.finished = true; recognition.cancel() }
        let result = await XCTWaiter.fulfillment(of: [recognized], timeout: 20)
        if result != .completed {
            print("EXPRESSIVE_DIAGNOSTIC \(label) transcription_timeout=true")
            return
        }
        if let error = state.error {
            print("EXPRESSIVE_DIAGNOSTIC \(label) transcription_error=\(error)")
        }
        let expectedWords = Self.words(expected)
        let actualWords = Self.words(state.text)
        print("EXPRESSIVE_DIAGNOSTIC \(label) recognized=\(state.text) word_edit_distance=\(Self.wordDistance(expectedWords, actualWords)) expected_word_count=\(expectedWords.count)")
    }

    private static func number(_ value: Double) -> String { String(format: "%.3f", value) }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func wordDistance(_ first: [String], _ second: [String]) -> Int {
        var previous = Array(0...second.count)
        for (index, word) in first.enumerated() {
            var row = [index + 1]
            for (otherIndex, otherWord) in second.enumerated() {
                row.append(min(row[otherIndex] + 1, previous[otherIndex + 1] + 1,
                               previous[otherIndex] + (word == otherWord ? 0 : 1)))
            }
            previous = row
        }
        return previous[second.count]
    }

    @MainActor
    private final class Transcription {
        var finished = false
        var text = ""
        var error: String?
    }
}
