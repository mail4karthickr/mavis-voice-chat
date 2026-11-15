import AVFoundation
import Speech
import XCTest
@testable import MarvisVoice

final class SpeechTextTests: XCTestCase {
    func testLongUnbrokenInputStaysWithinMarvisLimit() {
        let text = String(repeating: "界", count: 1600)
        let chunks = SpeechText.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 180 && !$0.isEmpty })
        XCTAssertEqual(chunks.joined(), text)
    }

    func testSentenceBoundariesAndWhitespace() {
        XCTAssertEqual(SpeechText.chunks("  Hello there. Next sentence.  ", limit: 15), ["Hello there.", "Next sentence."])
        XCTAssertEqual(SpeechText.chunks(" \n\t "), [])
    }

    func testALongSentenceIsCutAfterACommaNotInsideANumber() {
        let text = "Google was founded in 1998 by Larry Page and Sergey Brin, who met at Stanford and later raised 1,000,000 dollars."
        XCTAssertEqual(SpeechText.chunks(text, limit: 105), [
            "Google was founded in 1998 by Larry Page and Sergey Brin,",
            "who met at Stanford and later raised 1,000,000 dollars.",
        ])
        XCTAssertEqual(SpeechText.chunks(text, limit: 180), [text])
    }

    /// Supertonic takes 70 characters at a time, so where a long sentence is cut is heard.
    func testASentenceIsCutIntoEvenPiecesAtItsNaturalBreaks() {
        XCTAssertEqual(SpeechText.clauses("Google was founded in 1998 by Larry Page and Sergey Brin.", limit: 70),
                       ["Google was founded in 1998 by Larry Page and Sergey Brin."])
        // After a comma.
        XCTAssertEqual(
            SpeechText.clauses("India has a rich history spanning thousands of years, including ancient empires and a long history of cultural diversity.", limit: 70),
            ["India has a rich history spanning thousands of years,",
             "including ancient empires and a long history of cultural diversity."]
        )
        // Without one, before a joining word, not wherever the 70th character falls.
        XCTAssertEqual(
            SpeechText.clauses("It gained independence from British rule in 1947 and has since become a major democratic nation.", limit: 70),
            ["It gained independence from British rule in 1947", "and has since become a major democratic nation."]
        )
        // An early comma is passed over when the rest would not fit in one more piece,
        // and a comma inside a number is never a break.
        XCTAssertEqual(
            SpeechText.clauses("However, the committee decided to postpone the final vote for another three weeks.", limit: 70),
            ["However, the committee decided to postpone", "the final vote for another three weeks."]
        )
        XCTAssertEqual(
            SpeechText.clauses("The telescope recorded 1,000,000 separate images of the northern sky over a period of six years.", limit: 70),
            ["The telescope recorded 1,000,000 separate images", "of the northern sky over a period of six years."]
        )
        XCTAssertEqual(SpeechText.clauses(" \n ", limit: 70), [])
        XCTAssertEqual(SpeechText.clauses(String(repeating: "界", count: 150), limit: 70).map(\.count), [70, 70, 10])
    }

    /// Kokoro reads the hyphen in a compound as a dash and pauses there.
    func testCompoundWordsLoseTheirHyphenButRangesKeepIt() {
        XCTAssertEqual(
            SpeechText.joiningHyphenatedWords("A 1000-word, well-known state-of-the-art e-mail."),
            "A 1000 word, well known state of the art e mail."
        )
        let untouched = "In 1990-2000 it fell to -5, mostly - not always."
        XCTAssertEqual(SpeechText.joiningHyphenatedWords(untouched), untouched)
    }

    func testNoWordsLostAcrossChunkBoundaries() {
        let words = (0..<200).map { "word\($0)" }
        let chunks = SpeechText.chunks(words.joined(separator: " "))
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").map(String.init), words)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 180 })
    }
}

final class SpeechAudioTests: XCTestCase {
    func testTrimsThePaddingAroundSpeechAndKeepsAShortGap() {
        let rate = 24_000
        func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }
        let speech = [Float](repeating: 0.2, count: rate)
        let trimmed = SpeechAudio.trimmingSilence(silence(0.31) + speech + silence(0.53), sampleRate: rate)
        XCTAssertEqual(Double(trimmed.count) / Double(rate), 0.05 + 1 + 0.3, accuracy: 0.001)
        XCTAssertEqual(trimmed[Int(0.05 * Double(rate))], 0.2)

        // Audio without padding, and audio with nothing but silence, stay as they are.
        XCTAssertEqual(SpeechAudio.trimmingSilence(speech, sampleRate: rate), speech)
        XCTAssertEqual(SpeechAudio.trimmingSilence(silence(0.2), sampleRate: rate).count, silence(0.2).count)
    }
}

final class PCMPlayerTests: XCTestCase {
    /// Models that return a sentence at once hand the player several seconds in one call.
    /// The next sentence must still be queued before the current one runs out.
    @MainActor
    func testSentenceLengthBuffersPlayBackToBack() async throws {
        let player = PCMPlayer()
        defer { player.stop() }
        let sampleRate = 24_000
        try await player.enqueue([Float](repeating: 0, count: sampleRate * 4), sampleRate: sampleRate)
        try await player.enqueue([Float](repeating: 0, count: sampleRate), sampleRate: sampleRate)
        XCTAssertEqual(player.report.buffers, 10)
        XCTAssertEqual(player.report.underruns, 0)

        let drained = expectation(description: "The queued silence finishes playing")
        player.onDrained = { drained.fulfill() }
        player.finish()
        await fulfillment(of: [drained], timeout: 15)
    }
}

final class SpeechCaptureTests: XCTestCase {
    @MainActor
    func testAuthorizedCaptureCanStartAndCancelRepeatedly() async throws {
        // Exercise the real framework callbacks without displaying permission prompts.
        guard AVAudioApplication.shared.recordPermission == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Grant the app microphone and speech permissions to run the capture regression.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw XCTSkip("On-device English recognition is required for this integration test.")
        }

        let capture = SpeechCapture()
        defer { capture.cancel() }
        for _ in 0..<2 {
            try await capture.start()
            // Allow the audio thread to deliver buffers before tearing down the tap.
            try await Task.sleep(for: .milliseconds(300))
            capture.cancel()
        }
    }
}
