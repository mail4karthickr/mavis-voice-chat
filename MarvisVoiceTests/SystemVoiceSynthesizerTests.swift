import AVFoundation
import Speech
import XCTest
@testable import MarvisVoice

final class SystemVoiceSynthesizerTests: XCTestCase {
    @MainActor
    func testProducesSpeechBeforeTheTextStreamFinishes() async throws {
        let voice = SystemVoiceSynthesizer()
        let phrases = AsyncThrowingStream<String, Error>.makeStream()
        let firstAudio = expectation(description: "Non-silent PCM arrives while text is still streaming")
        let completed = expectation(description: "All supplied phrases finish synthesis")
        var heardAudio = false
        var finished = false
        let operation = Task { @MainActor in
            defer { finished = true; completed.fulfill() }
            try await voice.speak(phrases.stream) { samples, rate in
                XCTAssertGreaterThan(rate, 0)
                XCTAssertTrue(samples.allSatisfy(\.isFinite))
                if !heardAudio, samples.contains(where: { abs($0) > 0.0001 }) {
                    heardAudio = true
                    firstAudio.fulfill()
                }
            }
        }
        defer { operation.cancel(); voice.stop(); phrases.continuation.finish() }

        phrases.continuation.yield("Hello there.")
        let firstResult = await XCTWaiter.fulfillment(of: [firstAudio], timeout: 20)
        XCTAssertEqual(firstResult, .completed)
        XCTAssertFalse(finished, "Speech must begin before generation closes the text stream")
        phrases.continuation.yield("The next words are ready.")
        phrases.continuation.finish()
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed { operation.cancel(); voice.stop() }
        try await operation.value
    }

    @MainActor
    func testStopCancelsWhileWaitingForTheNextPhrase() async {
        let voice = SystemVoiceSynthesizer()
        let phrases = AsyncThrowingStream<String, Error>.makeStream()
        let ready = expectation(description: "Speech operation starts")
        let completed = expectation(description: "Stop wakes the waiting phrase consumer")
        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            ready.fulfill()
            try await voice.speak(phrases.stream) { _, _ in XCTFail("No phrase was supplied") }
        }
        defer { operation.cancel(); voice.stop(); phrases.continuation.finish() }
        let readyResult = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(readyResult, .completed)
        voice.stop()
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed { operation.cancel(); phrases.continuation.finish() }
        switch await operation.result {
        case .success: XCTFail("Stopping must propagate cancellation")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    @MainActor
    func testParentCancellationStopsWhileWaitingForText() async {
        let voice = SystemVoiceSynthesizer()
        let phrases = AsyncThrowingStream<String, Error>.makeStream()
        let ready = expectation(description: "Speech operation starts")
        let completed = expectation(description: "Caller cancellation reaches the phrase consumer")
        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            ready.fulfill()
            try await voice.speak(phrases.stream) { _, _ in XCTFail("No phrase was supplied") }
        }
        defer { operation.cancel(); voice.stop(); phrases.continuation.finish() }
        let readyResult = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(readyResult, .completed)
        operation.cancel()
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed { phrases.continuation.finish() }
        switch await operation.result {
        case .success: XCTFail("Caller cancellation must not look like a completed reply")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Decode the actual synthesized waveform on device. Checking utterance
    /// strings alone cannot catch a voice producing unrelated spoken words.
    @MainActor
    func testSynthesizedAudioSaysTheSuppliedWords() async throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Speech recognition must already be authorized for this audio round-trip test.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw XCTSkip("English on-device speech recognition is unavailable.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let recognized = expectation(description: "On-device recognition decodes the actual system voice PCM")
        let transcription = Transcription()
        let recognition = recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error?.localizedDescription
            Task { @MainActor in
                guard !transcription.finished, final || failure != nil else { return }
                transcription.finished = true
                transcription.text = text ?? ""
                transcription.error = failure
                recognized.fulfill()
            }
        }
        defer { recognition.cancel() }
        let voice = SystemVoiceSynthesizer()
        defer { voice.stop() }
        let phrase = "The red balloon is next to the blue chair."
        let phrases = AsyncThrowingStream<String, Error>.makeStream()
        phrases.continuation.yield(phrase)
        phrases.continuation.finish()
        try await voice.speak(phrases.stream) { samples, rate in
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            buffer.frameLength = buffer.frameCapacity
            request.append(buffer)
        }
        request.endAudio()
        let result = await XCTWaiter.fulfillment(of: [recognized], timeout: 20)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(transcription.error)
        let expected = Self.words(phrase)
        let actual = Self.words(transcription.text)
        // Speech recognition can miss an article or normalize one word. Extra
        // or unrelated generated speech still produces a large edit distance.
        XCTAssertLessThanOrEqual(Self.wordDistance(expected, actual), 1,
                                 "Expected '\(phrase)', heard '\(transcription.text)'")
    }

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
