import Foundation
import XCTest
@testable import BankVoice

final class BankVerbalizerTests: XCTestCase {
    @MainActor
    func testRealModelStreamsBeforeCompletionAndPreservesBothBalances() async throws {
        try requireModel()
        let reply = try await MockBankAPI(delay: .zero).fetch(.balance)
        let verbalizer = BankVerbalizer()
        verbalizer.prewarm()
        let started = ContinuousClock.now
        var snapshots: [String] = []
        var firstSnapshotAt: ContinuousClock.Instant?

        try await verbalizer.stream(reply: reply, query: BankScenario.balance.query) { snapshot in
            if firstSnapshotAt == nil { firstSnapshotAt = .now }
            snapshots.append(snapshot)
        }
        let completedAt = ContinuousClock.now
        let answer = try XCTUnwrap(snapshots.last)
        let first = try XCTUnwrap(firstSnapshotAt)
        print("BANK_MODEL balance=\(answer)")
        print("BANK_MODEL first_snapshot=\(started.duration(to: first)) completed=\(started.duration(to: completedAt)) snapshots=\(snapshots.count)")

        XCTAssertGreaterThan(snapshots.count, 1, "The real model must deliver an intermediate snapshot.")
        XCTAssertLessThan(try XCTUnwrap(snapshots.first).count, answer.count)
        XCTAssertLessThan(first, completedAt)
        let normalized = normalize(answer)
        XCTAssertTrue(normalized.contains("48250"), answer)
        XCTAssertTrue(normalized.contains("51250"), answer)
        XCTAssertTrue(normalized.contains("75 paise") || normalized.contains(".75"), answer)
        XCTAssertTrue(normalized.contains("available"), answer)
        XCTAssertTrue(normalized.contains("current"), answer)
        XCTAssertTrue(normalized.contains("rupee") || normalized.contains("inr") || normalized.contains("₹"), answer)
        XCTAssertTrue(normalized.replacingOccurrences(of: " ", with: "").contains("4821"), answer)
        XCTAssertTrue(normalized.contains("september") && normalized.contains("2026") && normalized.contains("18"), answer)
        XCTAssertFalse(normalized.contains("pending"), "No pending-transaction status was supplied: \(answer)")
        XCTAssertFalse(normalized.contains("completion"), "No payment completion information was supplied: \(answer)")
    }

    @MainActor
    func testRealModelPreservesPendingPaymentAndDoesNotInventCompletionDate() async throws {
        try requireModel()
        let reply = BankReply(
            scenario: .payment,
            json: #"{"demo":true,"payment":{"beneficiary":"Ravi Demo","amount":{"currency":"INR","minorUnits":325000},"status":"pending","estimatedCompletion":null}}"#,
            facts: [
                "Your existing demo payment of 3,250 rupees to Ravi Demo is pending and has not completed.",
                "The demo bank has not supplied an estimated completion time."
            ]
        )
        let verbalizer = BankVerbalizer()
        var answer = ""
        try await verbalizer.stream(reply: reply, query: "Did my payment to Ravi go through?") { answer = $0 }
        print("BANK_MODEL pending_payment=\(answer)")
        let normalized = normalize(answer)
        XCTAssertTrue(normalized.contains("pending"), answer)
        XCTAssertTrue(normalized.contains("3250"), answer)
        XCTAssertTrue(normalized.contains("ravi"), answer)
        XCTAssertTrue(normalized.contains("rupee") || normalized.contains("inr") || normalized.contains("₹"), answer)
        XCTAssertFalse(normalized.contains("successfully"), answer)
        XCTAssertFalse(normalized.contains("will complete"), answer)
        XCTAssertTrue(
            normalized.contains("no estimated") || normalized.contains("not supplied")
                || normalized.contains("not provided") || normalized.contains("hasn't supplied")
                || normalized.contains("hasn't provided") || normalized.contains("unknown")
                || normalized.contains("no completion") || normalized.contains("not available"),
            "The missing completion estimate must remain explicit: \(answer)"
        )
        let numbers = normalized.split(whereSeparator: { !$0.isNumber }).map(String.init)
        XCTAssertEqual(Set(numbers), ["3250"], "No completion date, duration, or additional amount may be invented: \(answer)")
    }

    @MainActor
    func testRealModelPreservesSupportedEndpointFactsWithoutInventingAmounts() async throws {
        try requireModel()
        let verbalizer = BankVerbalizer()
        for scenario in [BankScenario.transactions, .card, .payment] {
            let reply = try await MockBankAPI(delay: .zero).fetch(scenario)
            verbalizer.prewarm()
            var answer = ""
            try await verbalizer.stream(reply: reply, query: scenario.query) { answer = $0 }
            print("BANK_MODEL endpoint=\(scenario.rawValue) answer=\(answer)")
            let normalized = normalize(answer)
            let amounts = try rupeeAmountsInPaise(normalized)
            let expectedAmounts: Set<Int>
            let allowedNumbers: Set<String>

            switch scenario {
            case .transactions:
                expectedAmounts = [184_550, 79_900, 7_500_000]
                allowedNumbers = ["3", "1845", "50", "1845.50", "1845.5", "799", "799.00", "75000", "75000.00", "17", "16", "15", "2026", "09", "9"]
                for name in ["grocerlane demo", "cloudtel demo", "example employer"] {
                    XCTAssertTrue(normalized.contains(name), "Missing merchant or sender: \(answer)")
                }
                for day in [17, 16, 15] {
                    XCTAssertTrue(containsSeptember2026Date(day: day, in: normalized), "Missing exact transaction date: \(answer)")
                }
                XCTAssertTrue(["spent", "paid", "debited", "debit"].contains(where: normalized.contains), answer)
                XCTAssertTrue(["received", "credited", "credit"].contains(where: normalized.contains), answer)
                XCTAssertFalse(normalized.contains("pending"), "No pending transaction was supplied: \(answer)")
            case .card:
                expectedAmounts = [20_000_000, 17_245_025]
                allowedNumbers = ["9012", "9", "0", "1", "2", "200000", "200000.00", "172450", "25", "172450.25"]
                XCTAssertNotNil(normalized.range(of: #"\bactive\b"#, options: .regularExpression), answer)
                XCTAssertFalse(normalized.contains("inactive") || normalized.contains("blocked"), answer)
                XCTAssertTrue(normalized.contains("total") || normalized.contains("credit limit"), answer)
                XCTAssertTrue(normalized.contains("available"), answer)
                XCTAssertTrue(normalized.replacingOccurrences(of: " ", with: "").contains("9012"), answer)
            case .payment:
                expectedAmounts = [1_250_000]
                allowedNumbers = ["12500", "12500.00", "17", "2026", "09", "9"]
                XCTAssertTrue(normalized.contains("asha demo"), answer)
                XCTAssertTrue(normalized.contains("completed"), answer)
                XCTAssertFalse(normalized.contains("pending") || normalized.contains("failed"), answer)
                XCTAssertTrue(containsSeptember2026Date(day: 17, in: normalized), answer)
                XCTAssertTrue(
                    normalized.contains("no new payment") || normalized.contains("no additional payment")
                        || normalized.contains("not made a new payment") || normalized.contains("not make a new payment")
                        || normalized.contains("without making a new payment"),
                    "The response must not imply that it performed a new payment: \(answer)"
                )
            case .balance:
                XCTFail("Balance has its own streaming fidelity test.")
                continue
            }

            XCTAssertEqual(Set(amounts), expectedAmounts, "Missing, changed, or invented currency amount: \(answer)")
            let numericPattern = try NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
            let numericTokens = numericPattern.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
                .compactMap { Range($0.range, in: normalized).map { String(normalized[$0]) } }
            XCTAssertTrue(Set(numericTokens).isSubset(of: allowedNumbers), "Invented numeric fact: \(answer)")
        }
    }

    @MainActor
    func testAlreadyCancelledRequestEmitsNoWording() async throws {
        let reply = try await MockBankAPI(delay: .zero).fetch(.payment)
        let verbalizer = BankVerbalizer()
        var snapshots: [String] = []
        let task = Task { @MainActor in
            try await verbalizer.stream(reply: reply, query: BankScenario.payment.query) { snapshots.append($0) }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled request must throw CancellationError.")
        } catch is CancellationError {
            XCTAssertTrue(snapshots.isEmpty)
        }
    }

    @MainActor
    private func requireModel() throws {
        if let issue = BankVerbalizer.availabilityIssue {
            throw XCTSkip(issue)
        }
    }

    private func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "’", with: "'")
    }

    /// Accept both decimal currency (INR 1845.50) and spoken units
    /// (1845 rupees and 50 paise), while comparing exact integer paise.
    private func rupeeAmountsInPaise(_ text: String) throws -> [Int] {
        let pattern = #"(?:(?:₹|inr|rs\.?)\s*(\d+(?:\.\d{1,2})?)|(\d+(?:\.\d{1,2})?)\s*(?:rupees?|inr))(?:\s*(?:and\s*)?(\d{1,2})\s*(?:paise|paisa))?"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            let amountRange = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            guard let range = Range(amountRange, in: text) else { return nil }
            let parts = text[range].split(separator: ".")
            guard let rupees = parts.first.flatMap({ Int($0) }) else { return nil }
            let decimalPaise = parts.count == 2 ? Int(String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0 : 0
            let spokenPaise = Range(match.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 0
            return rupees * 100 + decimalPaise + spokenPaise
        }
    }

    private func containsSeptember2026Date(day: Int, in text: String) -> Bool {
        let pattern = "(?:\\b\(day)(?:st|nd|rd|th)?\\s+sep(?:tember)?\\s+2026\\b|\\bsep(?:tember)?\\s+\(day)(?:st|nd|rd|th)?\\s+2026\\b|\\b2026[-/]0?9[-/]\(day)\\b)"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
