// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import XCTest
@testable import SpeakFreeKeyboardCore

final class DictationTextFormatterTests: XCTestCase {
    func testCapitalizesAtEmptyDocumentAndAfterSentenceBoundary() {
        XCTAssertEqual(
            DictationTextFormatter.format(
                "hello world. another sentence",
                contextBeforeInput: "",
                capitalization: .sentences
            ),
            "Hello world. Another sentence"
        )
        XCTAssertEqual(
            DictationTextFormatter.format(
                "next thought",
                contextBeforeInput: "Already done! ” ",
                capitalization: .sentences
            ),
            "Next thought"
        )
    }

    func testDoesNotCapitalizeMidSentence() {
        XCTAssertEqual(
            DictationTextFormatter.format(
                "continues here",
                contextBeforeInput: "This sentence ",
                capitalization: .sentences
            ),
            "continues here"
        )
    }

    func testHonorsNoneWordsAndAllCharactersTraits() {
        XCTAssertEqual(
            DictationTextFormatter.format(
                "lower case",
                contextBeforeInput: "",
                capitalization: .none
            ),
            "lower case"
        )
        XCTAssertEqual(
            DictationTextFormatter.format(
                "two useful words",
                contextBeforeInput: " ",
                capitalization: .words
            ),
            "Two Useful Words"
        )
        XCTAssertEqual(
            DictationTextFormatter.format(
                "mixed Case 42",
                contextBeforeInput: "anything",
                capitalization: .allCharacters
            ),
            "MIXED CASE 42"
        )
    }

    func testPreservesExistingModelCasingAndPunctuation() {
        XCTAssertEqual(
            DictationTextFormatter.format(
                "iPhone and NASA are names.",
                contextBeforeInput: "",
                capitalization: .sentences
            ),
            "iPhone and NASA are names."
        )
        XCTAssertEqual(
            DictationTextFormatter.format(
                "eBay works. ordinary words",
                contextBeforeInput: "",
                capitalization: .sentences
            ),
            "eBay works. Ordinary words"
        )
    }
}
