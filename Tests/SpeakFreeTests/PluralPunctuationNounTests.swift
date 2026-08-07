// Claude · 2026-08-05 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// Meaning-destroying bug from the speech audit (build/26-07-25-speech-audit, finding 3; Michael
// approved fixing): the spoken-punctuation table matched `question marks?` — the trailing `s?`
// swallowed the PLURAL NOUN. So "the people with question marks" became "the people with?",
// deleting the subject of the sentence. ~5 of 6,571 pairs, but each one destroys content rather
// than leaving a visible garble.
//
// Fix: spoken punctuation commands are dictated in the SINGULAR ("question mark", "exclamation
// point"). The plural is essentially always the literal noun, so the command patterns no longer
// accept it. Failure direction matters here — leaving the words visible costs a manual edit,
// while converting them silently deletes what Michael said.

import XCTest
@testable import SpeakFreeLib

final class PluralPunctuationNounTests: XCTestCase {

    private func hybrid(_ t: String) -> String { TextPostProcessor.process(t, hybrid: true) }
    private func spoken(_ t: String) -> String { TextPostProcessor.process(t, hybrid: false) }

    // MARK: - The reported defect

    /// The audit's own example.
    func test_pluralQuestionMarksSurvivesAsNoun() {
        let input = "Tell me more about the people with question marks"
        XCTAssertEqual(hybrid(input), input)
        XCTAssertEqual(spoken(input), input)
    }

    func test_pluralExclamationMarksSurvivesAsNoun() {
        let input = "He writes everything with exclamation marks"
        XCTAssertEqual(hybrid(input), input)
        XCTAssertEqual(spoken(input), input)
    }

    func test_pluralExclamationPointsSurvivesAsNoun() {
        let input = "Lose the exclamation points in the subject line"
        XCTAssertEqual(hybrid(input), input)
        XCTAssertEqual(spoken(input), input)
    }

    /// Mid-sentence, where the deletion is most destructive — everything after the noun
    /// used to be glued onto a bare "?".
    func test_pluralMidSentenceKeepsTheRestOfTheSentence() {
        let input = "The rows with question marks need review before Friday"
        let out = hybrid(input)
        XCTAssertEqual(out, input)
        XCTAssertTrue(out.contains("need review before Friday"),
                      "content after the noun must survive: \(out)")
    }

    // MARK: - The singular command must still convert (no regression)

    func test_singularQuestionMarkStillConverts() {
        XCTAssertFalse(spoken("what time is it question mark").contains("question mark"))
        XCTAssertTrue(spoken("what time is it question mark").contains("?"))
    }

    func test_singularExclamationStillConverts() {
        XCTAssertTrue(spoken("that is amazing exclamation point").contains("!"))
        XCTAssertTrue(spoken("that is amazing exclamation mark").contains("!"))
    }
}
