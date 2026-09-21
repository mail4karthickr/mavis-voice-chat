import FoundationModels
import XCTest
@testable import BankVoice

final class BankVoicePipelineTests: XCTestCase {
    /// Exercise the actual default pipeline including the two-second mock API,
    /// the on-device wording model, Marvis inference, and scheduled PCM playback.
    @MainActor
    func testBankJSONBecomesStreamingSpeechOnDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Marvis inference requires a physical Apple Silicon device.")
        #else
        guard BankVerbalizer.availabilityIssue == nil else {
            throw XCTSkip("Apple's on-device model is unavailable.")
        }
        let bank = BankController()
        defer { bank.stop() }
        bank.prepareVoice()
        try await waitUntil(timeout: 120) { !bank.isBusy }
        try XCTUnwrap(bank.error == nil ? true : nil, bank.error ?? "")
        XCTAssertTrue(bank.voiceReady)
        bank.ask(.balance)
        try await waitUntil(timeout: 90) { !bank.isBusy }
        XCTAssertNil(bank.error)
        XCTAssertEqual(bank.messages.count, 2)
        XCTAssertTrue(bank.latestJSON.contains("4825075"))
        let api = try XCTUnwrap(bank.metrics.apiSeconds)
        let text = try XCTUnwrap(bank.metrics.firstTextSeconds)
        let audio = try XCTUnwrap(bank.metrics.firstAudioSeconds)
        let textComplete = try XCTUnwrap(bank.metrics.textCompleteSeconds)
        let total = try XCTUnwrap(bank.metrics.totalSeconds)
        XCTAssertGreaterThanOrEqual(api, 1.95)
        XCTAssertGreaterThanOrEqual(text, api)
        XCTAssertGreaterThanOrEqual(audio, text)
        XCTAssertGreaterThan(total, audio)
        print("BANK_PIPELINE api=\(api) first_text=\(text) first_audio_queued=\(audio) text_complete=\(textComplete) playback_complete=\(total)")
        print("BANK_PIPELINE spoken_text=\(bank.messages[1].text)")
        // Record overlap honestly. A very short JSON answer can finish text
        // before TTS starts; the pipeline itself never waits for full text.
        print("BANK_PIPELINE audio_overlaps_text=\(audio < textComplete)")
        #endif
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw VoiceChatError.message("Device pipeline timed out after \(timeout) seconds.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
