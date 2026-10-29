import XCTest
@testable import MarvisVoice

final class StreamingSpeechTextTests: XCTestCase {
    func testSpeaksCompletedSentenceBeforeResponseFinishes() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Hello there."), [])
        XCTAssertEqual(speech.append("Hello there. "), ["Hello there."])
        XCTAssertEqual(speech.append("Hello there. The rest is still arriving"), [])
        XCTAssertEqual(speech.finish(), ["The rest is still arriving"])
        XCTAssertEqual(speech.finish(), [])
    }

    func testCharacterByCharacterSnapshotsPreserveWordsAndPunctuation() {
        let answer = "Dr. Smith paid 3.14 dollars. \"Really?!\" Yes, and there is more to explain before the final unfinished sentence"
        var speech = MarvisStreamingSpeechText()
        var snapshot = ""
        var phrases: [String] = []
        for character in answer {
            snapshot.append(character)
            phrases += speech.append(snapshot)
        }
        phrases += speech.finish()
        XCTAssertEqual(phrases.first, "Dr. Smith paid 3.14")
        XCTAssertTrue(phrases.contains("\"Really?!\""))
        XCTAssertEqual(words(phrases.joined(separator: " ")), words(answer))
    }

    func testLongSentenceStartsSpeakingAtACompleteWord() {
        let words = (0..<80).map { "word\($0)" }
        var speech = MarvisStreamingSpeechText()
        var snapshot = ""
        var phrases: [String] = []
        for (index, word) in words.enumerated() {
            snapshot += (index == 0 ? "" : " ") + word
            phrases += speech.append(snapshot)
            if index == 20 { XCTAssertFalse(phrases.isEmpty) }
        }
        phrases += speech.finish()
        XCTAssertEqual(self.words(phrases.joined(separator: " ")), words)
        XCTAssertTrue(phrases.allSatisfy { $0.count <= 180 })
    }

    func testFirstFewWordsStartSpeakingWithoutWaitingForPunctuation() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("I can help you"), [])
        XCTAssertEqual(speech.append("I can help you plan"), ["I can help you"])
        XCTAssertEqual(speech.append("I can help you plan"), [])
        XCTAssertEqual(speech.append("I can help you plan a trip"), [])
        XCTAssertEqual(speech.finish(), ["plan a trip"])
    }

    func testFirstPhraseCanStartWithFewerLongWords() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Understanding asynchronous"), [])
        XCTAssertEqual(speech.append("Understanding asynchronous str"), ["Understanding asynchronous"])
        XCTAssertEqual(speech.finish(), ["str"])
    }

    func testLatencyFlushReleasesCompleteWordsAndPreservesPendingWord() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Hi th"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["Hi"])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.append("Hi there fr"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["there"])
        XCTAssertEqual(speech.append("Hi there friend"), [])
        XCTAssertEqual(speech.finish(), ["friend"])
        XCTAssertEqual(speech.flushReadyWords(), [])
    }

    func testNaturalSpeechBuffersShortIncompletePhrasesUntilCompletion() {
        var speech = MarvisStreamingSpeechText(style: .natural)
        XCTAssertEqual(speech.append("Hi th"), [])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.append("Hi there friend"), [])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.finish(), ["Hi there friend"])
        XCTAssertEqual(speech.finish(), [])
    }

    func testNaturalSpeechEmitsCompleteShortSentenceImmediately() {
        var speech = MarvisStreamingSpeechText(style: .natural)
        XCTAssertEqual(speech.append("Hello there. "), ["Hello there."])
        XCTAssertEqual(speech.append("Hello there. More is coming"), [])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.finish(), ["More is coming"])
    }

    func testNaturalSpeechStartsWithMeaningfulPhraseBeforeSentenceEnds() {
        var speech = MarvisStreamingSpeechText(style: .natural)
        let first = "I can explain how streaming audio"
        XCTAssertEqual(speech.append(first), [])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.append(first + " works"), [first])
        XCTAssertEqual(speech.append(first + " works in real time"), [])
        XCTAssertEqual(speech.finish(), ["works in real time"])
    }

    func testNaturalSpeechRequiresBothEnoughWordsAndEnoughCharacters() {
        var speech = MarvisStreamingSpeechText(style: .natural)
        XCTAssertEqual(speech.append("I am up to it and "), [])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.append("I am up to it and ready for tomorrow "),
                       ["I am up to it and ready for tomorrow"])
        XCTAssertEqual(speech.finish(), [])

        var longWords = MarvisStreamingSpeechText(style: .natural)
        let phrase = String(repeating: "a", count: 65) + " " + String(repeating: "b", count: 40)
        XCTAssertEqual(longWords.append(phrase + " next"), [])
        XCTAssertEqual(longWords.flushReadyWords(), [])
        XCTAssertEqual(longWords.finish().joined(separator: " "), phrase + " next")
    }

    func testNaturalLatencyFlushRequiresPhraseContextAfterFirstSentence() {
        var speech = MarvisStreamingSpeechText(style: .natural)
        XCTAssertEqual(speech.append("Hello there. "), ["Hello there."])
        let first = "I can explain how streaming audio"
        XCTAssertEqual(speech.append("Hello there. " + first + " works"), [])
        XCTAssertEqual(speech.flushReadyWords(), [first])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.finish(), ["works"])
    }

    func testImmediateStyleRetainsSingleWordLatencyFlush() {
        var speech = MarvisStreamingSpeechText(style: .immediate)
        XCTAssertEqual(speech.append("Hi th"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["Hi"])
        XCTAssertEqual(speech.append("Hi there"), [])
        XCTAssertEqual(speech.finish(), ["there"])
    }

    func testLatencyFlushKeepsAbbreviationWithFollowingWord() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("A note about Dr. Sm"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["A note about"])
        XCTAssertEqual(speech.flushReadyWords(), [])
        XCTAssertEqual(speech.append("A note about Dr. Smith "), [])
        XCTAssertEqual(speech.flushReadyWords(), ["Dr. Smith"])
        XCTAssertEqual(speech.finish(), [])
    }

    func testLatencyFlushPreservesUnicodeAndAllowsPendingRevision() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Hi 👨‍👩‍👧‍👦 ca"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["Hi 👨‍👩‍👧‍👦"])
        XCTAssertEqual(speech.append("Hi 👨‍👩‍👧‍👦 café time"), [])
        XCTAssertEqual(speech.flushReadyWords(), ["café"])
        XCTAssertEqual(speech.append("Hi 👨‍👩‍👧‍👦 café today"), [])
        XCTAssertEqual(speech.finish(), ["today"])
    }

    func testUnspokenSuffixCanBeRevisedWithoutRepeatingSpokenPrefix() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Hello there. The answer is red"), ["Hello there."])
        XCTAssertEqual(speech.append("Hello there. The answer is blue. "), ["The answer is blue."])
        XCTAssertEqual(speech.append("Hello there. The answer is blue. "), [])
        XCTAssertEqual(speech.finish(), [])
    }

    func testSpokenPrefixRevisionAdjustsCursorToUnchangedPendingSuffix() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append("Hello there. More is coming"), ["Hello there."])
        XCTAssertEqual(speech.append("Hello, my friend. More is coming"), [])
        XCTAssertEqual(speech.append("Hello, my friend. More is coming. "), ["More is coming."])
        XCTAssertEqual(speech.finish(), [])
    }

    func testUnicodeSnapshotsPreserveGraphemesAndNonLatinSentences() {
        let answer = "Hello 👨‍👩‍👧‍👦, café! こんにちは。今日はいい天気です。 An unfinished résumé"
        var speech = MarvisStreamingSpeechText()
        var snapshot = ""
        var phrases: [String] = []
        for character in answer {
            snapshot.append(character)
            phrases += speech.append(snapshot)
        }
        phrases += speech.finish()
        XCTAssertEqual(phrases, ["Hello 👨‍👩‍👧‍👦, café!", "こんにちは。", "今日はいい天気です。", "An unfinished résumé"])
    }

    func testOversizedUnspacedTextIsBoundedAndNeverDropped() {
        let answer = String(repeating: "界", count: 600)
        var speech = MarvisStreamingSpeechText()
        let phrases = speech.append(answer) + speech.finish()
        XCTAssertEqual(phrases.joined(), answer)
        XCTAssertTrue(phrases.allSatisfy { $0.count <= 180 })
    }

    func testEmptySnapshotsAndTrailingWhitespaceDoNotProduceSpeech() {
        var speech = MarvisStreamingSpeechText()
        XCTAssertEqual(speech.append(" \n\t "), [])
        XCTAssertEqual(speech.finish(), [])
    }

    private func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
