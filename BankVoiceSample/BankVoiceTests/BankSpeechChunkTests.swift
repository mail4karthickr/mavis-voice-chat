import XCTest
@testable import BankVoice

final class BankSpeechChunkTests: XCTestCase {
    func testAmountAndItsPaiseStayTogetherBeforeSpeechStarts() {
        var text = StreamingSpeechText(style: .sentences)
        XCTAssertEqual(text.append("You have 48,250 rupees and 75 "), [])
        XCTAssertEqual(text.flushReadyWords(), [])
        XCTAssertEqual(text.append("You have 48,250 rupees and 75 paise available. Your current"),
                       ["You have 48,250 rupees and 75 paise available."])
        XCTAssertEqual(text.finish(), ["Your current"])
    }

    func testFirstCompleteSentenceStreamsBeforeRemainingReply() {
        var text = StreamingSpeechText(style: .sentences)
        XCTAssertEqual(text.append("Your card is active. Your available credit is"), ["Your card is active."])
        XCTAssertEqual(text.append("Your card is active. Your available credit is 172,450 rupees and 25 paise."), [])
        XCTAssertEqual(text.finish(), ["Your available credit is 172,450 rupees and 25 paise."])
    }

    func testLongAccountSentenceIsNotSplitAtNinetyCharacters() {
        var text = StreamingSpeechText(style: .sentences)
        let sentence = "Your demo savings account ending in 4 8 2 1 has 48,250 rupees and 75 paise available as of 18 September 2026."
        XCTAssertEqual(text.append(String(sentence.dropLast())), [])
        XCTAssertEqual(text.flushReadyWords(), [])
        XCTAssertEqual(text.append(sentence + " Next"), [sentence])
    }
}
