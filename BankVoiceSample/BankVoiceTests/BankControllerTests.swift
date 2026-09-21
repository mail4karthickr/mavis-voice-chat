import XCTest
@testable import BankVoice

final class BankControllerTests: XCTestCase {
    @MainActor
    func testDirectReplyComesFromDecodedAPIAndRecordsTiming() async throws {
        let bank = BankController(api: MockBankAPI(delay: .milliseconds(40)))
        bank.mode = .direct
        bank.readAloud = false
        bank.ask(.balance)
        XCTAssertEqual(bank.phase, .requesting)
        XCTAssertTrue(bank.latestJSON.isEmpty)
        try await waitForIdle(bank)
        XCTAssertNil(bank.error)
        XCTAssertEqual(bank.messages.count, 2)
        XCTAssertTrue(bank.messages[1].text.contains("48,250 rupees and 75 paise"))
        XCTAssertTrue(bank.latestJSON.contains("4825075"))
        XCTAssertEqual(bank.latestEndpoint, BankScenario.balance.endpoint)
        let api = try XCTUnwrap(bank.metrics.apiSeconds)
        let firstText = try XCTUnwrap(bank.metrics.firstTextSeconds)
        XCTAssertGreaterThanOrEqual(api, 0.035)
        XCTAssertGreaterThanOrEqual(firstText, api)
        XCTAssertNil(bank.metrics.firstAudioSeconds, "Text-only turns must not pretend to have played audio")
        XCTAssertNotNil(bank.metrics.totalSeconds)
    }

    @MainActor
    func testStopDuringAPIWaitCannotPublishStaleJSONOrAnswer() async throws {
        let bank = BankController(api: MockBankAPI(delay: .milliseconds(150)))
        bank.mode = .direct
        bank.readAloud = false
        bank.ask(.balance)
        bank.stop()
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(bank.phase, .idle)
        XCTAssertTrue(bank.latestJSON.isEmpty)
        XCTAssertTrue(bank.messages.allSatisfy(\.isUser))
        XCTAssertNil(bank.metrics.apiSeconds)
        XCTAssertNil(bank.error)
    }

    @MainActor
    func testResetAndNewRequestIsolatesAnInterruptedTurn() async throws {
        let bank = BankController(api: MockBankAPI(delay: .milliseconds(40)))
        bank.mode = .direct
        bank.readAloud = false
        bank.ask(.balance)
        bank.reset()
        bank.ask(.payment)
        try await waitForIdle(bank)
        XCTAssertEqual(bank.messages.count, 2)
        XCTAssertEqual(bank.latestEndpoint, BankScenario.payment.endpoint)
        XCTAssertTrue(bank.messages[1].text.contains("Asha Demo"))
        XCTAssertFalse(bank.messages[1].text.contains("48,250"))
    }

    @MainActor
    func testUnsupportedQueryDoesNotPretendToCallABankingAPI() {
        let bank = BankController(api: MockBankAPI(delay: .zero))
        bank.mode = .direct
        bank.readAloud = false
        bank.draft = "Transfer money to Asha now"
        bank.sendDraft()
        XCTAssertNotNil(bank.error)
        XCTAssertEqual(bank.phase, .idle)
        XCTAssertTrue(bank.messages.isEmpty)
        XCTAssertTrue(bank.latestJSON.isEmpty)
    }

    @MainActor
    private func waitForIdle(_ bank: BankController) async throws {
        for _ in 0..<100 {
            if bank.phase == .idle { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Mock banking turn did not finish within one second")
    }
}
