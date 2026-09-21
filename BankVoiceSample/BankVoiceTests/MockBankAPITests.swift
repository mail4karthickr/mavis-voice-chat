import XCTest
@testable import BankVoice

final class MockBankAPITests: XCTestCase, @unchecked Sendable {
    func testEachExampleRoutesToItsOwnEndpoint() {
        for scenario in BankScenario.allCases {
            XCTAssertEqual(BankScenario.route(scenario.query), scenario)
            XCTAssertTrue(scenario.endpoint.hasPrefix("/mock/v1/"))
        }
        XCTAssertEqual(BankScenario.route("Please show my BALANCE!"), .balance)
        XCTAssertEqual(BankScenario.route("Show my account statement"), .transactions)
        XCTAssertEqual(BankScenario.route("What is my credit limit?"), .card)
        XCTAssertEqual(BankScenario.route("What is the status of my transfer?"), .payment)
        XCTAssertEqual(BankScenario.route("Please check my transfer status now"), .payment)
    }

    func testUnknownQuestionsAndMutationIntentsDoNotBecomeStatusReplies() {
        for query in [
            "", "What's the weather?", "What is my loan balance?", "Apply for a credit card",
            "Transfer money to Asha", "Transfer money and show payment status", "Send 500 rupees",
            "Pay my card bill", "Make a payment", "Block my card", "Increase my credit limit",
            "Cancel this payment", "Open a savings account", "Change the transfer status",
            "Transfer 500 rupees to Asha now and show its status",
            "Transfer 500 rupees to Asha and show the transfer status",
            "Check my transfer status and transfer another 500 rupees"
        ] {
            XCTAssertNil(BankScenario.route(query), query)
        }
    }

    func testDecodedResponsesContainNestedJSONAndExactIsolatedFacts() async throws {
        let api = MockBankAPI(delay: .zero)
        for scenario in BankScenario.allCases {
            let reply = try await api.fetch(scenario)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any])
            let customer = try XCTUnwrap(json["customer"] as? [String: Any])
            let data = try XCTUnwrap(json["data"] as? [String: Any])
            XCTAssertEqual(reply.scenario, scenario)
            XCTAssertEqual(json["demo"] as? Bool, true)
            XCTAssertEqual(json["endpoint"] as? String, scenario.endpoint)
            XCTAssertEqual(customer["alias"] as? String, "Sample Customer")
            XCTAssertFalse(reply.facts.isEmpty)
            XCTAssertEqual(reply.directSpeech, reply.facts.joined(separator: " "))

            switch scenario {
            case .balance:
                let available = try XCTUnwrap(data["availableBalance"] as? [String: Any])
                XCTAssertEqual(available["minorUnits"] as? Int, 4_825_075)
                XCTAssertEqual(available["currency"] as? String, "INR")
                XCTAssertEqual(reply.facts, [
                    "Your demo savings account ending in 4 8 2 1 has 48,250 rupees and 75 paise available as of 18 September 2026.",
                    "Your current balance is 51,250 rupees and 75 paise."
                ])
                XCTAssertNil(data["payment"])
            case .transactions:
                let transactions = try XCTUnwrap(data["transactions"] as? [[String: Any]])
                XCTAssertEqual(transactions.count, 3)
                XCTAssertEqual(reply.facts.count, 4)
                XCTAssertEqual(reply.facts[1], "On 17 September 2026, you spent 1,845 rupees and 50 paise at Grocerlane Demo.")
                XCTAssertEqual(reply.facts[2], "On 16 September 2026, you spent 799 rupees at CloudTel Demo.")
                XCTAssertEqual(reply.facts[3], "On 15 September 2026, you received 75,000 rupees from Example Employer.")
                XCTAssertNil(data["card"])
            case .card:
                let card = try XCTUnwrap(data["card"] as? [String: Any])
                XCTAssertEqual(card["lastFour"] as? String, "9012")
                XCTAssertEqual(reply.facts, [
                    "Your demo credit card ending in 9 0 1 2 is active.",
                    "The total credit limit is 200,000 rupees.",
                    "Your available credit is 172,450 rupees and 25 paise."
                ])
                XCTAssertNil(data["transactions"])
            case .payment:
                let payment = try XCTUnwrap(data["payment"] as? [String: Any])
                XCTAssertEqual(payment["id"] as? String, "DEMO-PAY-20260917-01")
                XCTAssertEqual(payment["status"] as? String, "completed")
                XCTAssertEqual(reply.facts, [
                    "Your existing demo payment of 12,500 rupees to Asha Demo completed on 17 September 2026.",
                    "This is the status of an existing payment. No new payment was made."
                ])
                XCTAssertNil(data["availableBalance"])
            }
        }
    }

    func testDefaultRequestActuallyWaitsTwoSeconds() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await MockBankAPI().fetch(.balance)
        XCTAssertGreaterThanOrEqual(started.duration(to: clock.now), .seconds(2))
    }

    func testCancellationInterruptsTheMockNetworkDelay() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let request = Task { try await MockBankAPI(delay: .seconds(30)).fetch(.payment) }
        try await Task.sleep(for: .milliseconds(30))
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A cancelled request must not produce a payment-status response")
        } catch is CancellationError {
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        }
    }
}
