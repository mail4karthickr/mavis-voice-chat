import FoundationModels
import XCTest
@testable import MarvisVoice

final class ReplyQualityTests: XCTestCase {
    @MainActor
    func testReplyUsesPersonalFactProvidedInConversation() async throws {
        try requireModel()
        let session = LanguageModelSession(model: .default, instructions: ChatController.modelInstructions)
        _ = try await session.respond(to: "My dog's name is Mango.", options: ChatController.generationOptions)
        let reply = try await session.respond(to: "What is my dog's name?", options: ChatController.generationOptions)
        XCTAssertTrue(reply.content.lowercased().contains("mango"), reply.content)
    }

    @MainActor
    func testReplyAsksForAnUnknownPersonalFactInsteadOfInventingIt() async throws {
        try requireModel()
        let session = LanguageModelSession(model: .default, instructions: ChatController.modelInstructions)
        let reply = try await session.respond(
            to: "What is my dog's name?", options: ChatController.generationOptions
        )
        let text = reply.content.lowercased().replacingOccurrences(of: "’", with: "'")
        print("REPLY_QUALITY unknown_personal_fact=\(reply.content)")
        XCTAssertTrue(
            ["don't know", "do not know", "haven't", "not told", "tell me", "could you", "can you", "what's", "what is", "don't have"].contains(where: text.contains),
            "The reply should acknowledge missing information or ask for it: \(reply.content)"
        )
    }

    private func requireModel() throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple's on-device model is required for reply quality checks.")
        }
    }
}
