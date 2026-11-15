import XCTest
@testable import MarvisVoice

final class StreamingReplyTests: XCTestCase {
    private enum Failure: Error, Equatable {
        case source
        case speaker
    }

    @MainActor
    func testFirstWordsAreSpokenWhileAnUnpunctuatedStreamIsStillOpen() async throws {
        let source = AsyncThrowingStream<String, Error>.makeStream()
        let firstPhrase = expectation(description: "First words delivered without a sentence or completion")
        var spoken: [String] = []
        var generationFinished = false
        let operation = Task { @MainActor in
            try await StreamingReply.run { receive in
                for try await snapshot in source.stream { receive(snapshot) }
                generationFinished = true
            } speak: { phrases in
                for try await phrase in phrases {
                    spoken.append(phrase)
                    if spoken.count == 1 { firstPhrase.fulfill() }
                }
            }
        }
        defer { operation.cancel(); source.continuation.finish() }

        source.continuation.yield("A useful ")
        let result = await XCTWaiter.fulfillment(of: [firstPhrase], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(generationFinished)
        XCTAssertEqual(spoken, ["A useful"])
        source.continuation.yield("A useful answer")
        source.continuation.finish()
        try await operation.value
        XCTAssertEqual(spoken, ["A useful", "answer"])
    }

    @MainActor
    func testSpeechStartsBeforeGenerationFinishesAndKeepsPhraseOrder() async throws {
        let source = AsyncThrowingStream<String, Error>.makeStream()
        let firstPhrase = expectation(description: "Speech receives a sentence while generation is open")
        let completed = expectation(description: "Generation and speech finish")
        var generationFinished = false
        var spoken: [String] = []

        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await StreamingReply.run { receive in
                for try await snapshot in source.stream {
                    receive(snapshot)
                }
                generationFinished = true
            } speak: { phrases in
                for try await phrase in phrases {
                    spoken.append(phrase)
                    if spoken.count == 1 { firstPhrase.fulfill() }
                }
            }
        }
        defer {
            operation.cancel()
            source.continuation.finish()
        }

        source.continuation.yield("Hello there. ")
        let firstResult = await XCTWaiter.fulfillment(of: [firstPhrase], timeout: 2)
        XCTAssertEqual(firstResult, .completed)
        XCTAssertFalse(generationFinished)
        XCTAssertEqual(spoken, ["Hello there."])

        source.continuation.yield("Hello there. Another sentence! ")
        source.continuation.yield("Hello there. Another sentence! Final words")
        source.continuation.finish()
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed { operation.cancel() }
        try await operation.value
        XCTAssertTrue(generationFinished)
        XCTAssertEqual(spoken, ["Hello there.", "Another sentence!", "Final words"])
    }

    @MainActor
    func testSourceFailureCancelsSpeechAlreadyInProgress() async {
        let source = AsyncThrowingStream<String, Error>.makeStream()
        let playback = AsyncThrowingStream<Void, Error>.makeStream()
        let started = expectation(description: "Speech is in progress")
        let playbackCancelled = expectation(description: "Pending speech is cancelled")
        let completed = expectation(description: "Pipeline propagates source failure")
        playback.continuation.onTermination = { reason in
            if case .cancelled = reason { playbackCancelled.fulfill() }
        }

        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await StreamingReply.run { receive in
                for try await snapshot in source.stream { receive(snapshot) }
            } speak: { phrases in
                for try await _ in phrases {
                    started.fulfill()
                    for try await _ in playback.stream { }
                    try Task.checkCancellation()
                }
            }
        }
        defer {
            operation.cancel()
            source.continuation.finish()
            playback.continuation.finish()
        }

        source.continuation.yield("Start speaking. ")
        let startResult = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(startResult, .completed)
        source.continuation.finish(throwing: Failure.source)
        let completionResult = await XCTWaiter.fulfillment(of: [completed, playbackCancelled], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed {
            operation.cancel()
            playback.continuation.finish()
        }
        switch await operation.result {
        case .success: XCTFail("Expected the model failure")
        case .failure(let error): XCTAssertEqual(error as? Failure, .source)
        }
    }

    @MainActor
    func testSpeechFailureCancelsGenerationStillWaitingForTokens() async {
        let source = AsyncThrowingStream<String, Error>.makeStream()
        let sourceCancelled = expectation(description: "Pending generation is cancelled")
        let completed = expectation(description: "Pipeline propagates speech failure")
        source.continuation.onTermination = { reason in
            if case .cancelled = reason { sourceCancelled.fulfill() }
        }

        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await StreamingReply.run { receive in
                for try await snapshot in source.stream { receive(snapshot) }
                try Task.checkCancellation()
            } speak: { phrases in
                for try await _ in phrases { throw Failure.speaker }
            }
        }
        defer {
            operation.cancel()
            source.continuation.finish()
        }

        source.continuation.yield("Start speaking. ")
        let completionResult = await XCTWaiter.fulfillment(of: [completed, sourceCancelled], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed {
            operation.cancel()
            source.continuation.finish()
        }
        switch await operation.result {
        case .success: XCTFail("Expected the speech failure")
        case .failure(let error): XCTAssertEqual(error as? Failure, .speaker)
        }
    }

    @MainActor
    func testCancellationStopsBothChildrenWhileWaitingForFirstSentence() async {
        let source = AsyncThrowingStream<String, Error>.makeStream()
        let generatorReady = expectation(description: "Generator is waiting")
        let speakerReady = expectation(description: "Speaker is waiting")
        let sourceCancelled = expectation(description: "Generation receives cancellation")
        let completed = expectation(description: "Pipeline returns after cancellation")
        source.continuation.onTermination = { reason in
            if case .cancelled = reason { sourceCancelled.fulfill() }
        }
        var speechFinished = false

        let operation = Task { @MainActor in
            defer { completed.fulfill() }
            try await StreamingReply.run { receive in
                generatorReady.fulfill()
                for try await snapshot in source.stream { receive(snapshot) }
                try Task.checkCancellation()
            } speak: { phrases in
                speakerReady.fulfill()
                defer { speechFinished = true }
                for try await _ in phrases { XCTFail("No complete sentence was generated") }
            }
        }
        defer {
            operation.cancel()
            source.continuation.finish()
        }

        let readyResult = await XCTWaiter.fulfillment(of: [generatorReady, speakerReady], timeout: 2)
        XCTAssertEqual(readyResult, .completed)
        operation.cancel()
        let completionResult = await XCTWaiter.fulfillment(of: [completed, sourceCancelled], timeout: 2)
        XCTAssertEqual(completionResult, .completed)
        if completionResult != .completed { source.continuation.finish() }
        switch await operation.result {
        case .success: XCTFail("Cancellation must not appear as a successful reply")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(speechFinished)
    }
}
