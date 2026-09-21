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

    func testNoWordsLostAcrossChunkBoundaries() {
        let words = (0..<200).map { "word\($0)" }
        let chunks = SpeechText.chunks(words.joined(separator: " "))
        XCTAssertEqual(chunks.joined(separator: " ").split(separator: " ").map(String.init), words)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 180 })
    }
}

final class SpeechCaptureTests: XCTestCase {
    @MainActor
    func testAuthorizedCaptureCanStartAndCancelRepeatedly() async throws {
        // Exercise the real framework callbacks without displaying permission prompts.
        guard AVAudioApplication.shared.recordPermission == .granted,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Grant Marvis microphone and speech permissions to run the capture regression.")
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
