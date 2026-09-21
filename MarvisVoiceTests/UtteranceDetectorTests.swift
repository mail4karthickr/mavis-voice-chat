import XCTest
@testable import MarvisVoice

final class UtteranceDetectorTests: XCTestCase {
    func testInitialSilenceNeverSubmitsAnEmptyTurn() {
        var detector = UtteranceDetector(startedAt: 100)
        detector.recordTranscript(" \n ", at: 101)
        XCTAssertNil(detector.poll(at: 102))
        XCTAssertNil(detector.poll(at: 129.9))
        XCTAssertEqual(detector.poll(at: 130), .noSpeech)
        XCTAssertNil(detector.poll(at: 131))
    }

    func testNoiseWithoutRecognizedWordsRecyclesTheSession() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordAudio(decibels: -20, at: 29.9)
        XCTAssertEqual(detector.poll(at: 30), .noSpeech)
    }

    func testShortPausesAndOngoingAudioDoNotEndATurn() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordTranscript("Tell me", at: 1)
        detector.recordAudio(decibels: -25, at: 1.2)
        XCTAssertNil(detector.poll(at: 2))
        // Recognition can stall while the person continues speaking.
        detector.recordAudio(decibels: -25, at: 3)
        XCTAssertNil(detector.poll(at: 3.8))
        detector.recordTranscript("Tell me about the weather", at: 3.9)
        XCTAssertNil(detector.poll(at: 4.5))
        XCTAssertEqual(detector.poll(at: 5.1), .utteranceEnded)
    }

    func testQuietAudioDoesNotPostponeTheEndpoint() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordTranscript("Hello", at: 1)
        detector.recordAudio(decibels: -24, at: 1.1)
        detector.recordAudio(decibels: -70, at: 2.1)
        XCTAssertEqual(detector.poll(at: 2.3), .utteranceEnded)
    }

    func testStationaryBackgroundNoiseDoesNotPreventTurnCompletion() {
        var detector = UtteranceDetector(startedAt: 0)
        // A fan exceeds the minimum threshold but becomes the room baseline.
        detector.recordAudio(decibels: -35, at: 0)
        detector.recordAudio(decibels: -34, at: 0.1)
        detector.recordAudio(decibels: -36, at: 0.2)
        detector.recordAudio(decibels: -20, at: 0.8)
        detector.recordTranscript("Hello", at: 1)
        detector.recordAudio(decibels: -21, at: 1.2)
        detector.recordAudio(decibels: -35, at: 1.8)
        XCTAssertNil(detector.poll(at: 2))
        detector.recordAudio(decibels: -34, at: 2.3)
        XCTAssertEqual(detector.poll(at: 2.4), .utteranceEnded)
    }

    func testDuplicateRecognitionCallbacksDoNotKeepListeningForever() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordTranscript("Hello", at: 1)
        detector.recordTranscript(" Hello ", at: 1.9)
        XCTAssertEqual(detector.poll(at: 2.2), .utteranceEnded)
    }

    func testFinalRecognitionEndsImmediatelyAndOnlyOnce() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordTranscript("Hello", at: 1)
        XCTAssertEqual(detector.finish(), .utteranceEnded)
        detector.recordAudio(decibels: -20, at: 2)
        detector.recordTranscript("Hello again", at: 2)
        XCTAssertNil(detector.finish())
        XCTAssertNil(detector.poll(at: 60))
    }

    func testEmptyFinalRecognitionRequestsAnotherListeningSession() {
        var detector = UtteranceDetector(startedAt: 0)
        XCTAssertEqual(detector.finish(), .noSpeech)
        XCTAssertNil(detector.finish())
    }

    func testLongSpeechFinishesBeforeRecognitionSessionLimit() {
        var detector = UtteranceDetector(startedAt: 0)
        detector.recordTranscript("A long request", at: 49.9)
        detector.recordAudio(decibels: -20, at: 49.9)
        XCTAssertNil(detector.poll(at: 49.9))
        XCTAssertEqual(detector.poll(at: 50), .utteranceEnded)
    }
}
