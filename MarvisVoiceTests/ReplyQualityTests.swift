import FoundationModels
import XCTest
@testable import MarvisVoice

/// Device-only: needs Apple Intelligence. Checks that the summarization prompt
/// turns a backend JSON reply into a short spoken answer rather than echoing it.
final class ReplyQualityTests: XCTestCase {
    @MainActor func testSummarizesBackendJSONIntoSpokenAnswer() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Foundation Models is unavailable on this device.")
        }
        let question = "What is my account balance?"
        let json = try await MockBackend().answer(question: question)
        let session = LanguageModelSession(model: .default, instructions: ChatController.modelInstructions)
        let reply = try await session.respond(
            to: ChatController.prompt(question: question, json: json),
            options: ChatController.generationOptions
        ).content
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(reply.contains("{") || reply.contains("_"), "A spoken answer must not echo JSON: \(reply)")
        XCTAssertTrue(reply.contains("48") || reply.lowercased().contains("forty"), "Expected the balance in: \(reply)")
    }
}
