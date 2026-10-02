// Claude · 2026-09-25 · Session: 718d5e6d-50b3-4f35-9f63-485e474dadf3
//
// The punctuation layer keeps every dictated line break (feat/punctuation-pass); the inserter
// then drops a trailing line break in every app (feat/app-compat-2). Together: a break in the
// middle of a dictation survives insertion, a break at the very end does not. Invented text.

import XCTest
@testable import SpeakFreeLib

final class LineBreakInsertionInteractionTests: XCTestCase {

    private func inserted(_ raw: String, _ mode: PunctuationMode) -> String {
        let text = TextPipeline.run(TextPipeline.Input(raw: raw, punctuationMode: mode),
                                    isRealWord: { _ in true }).finalText
        return AppCompatibility.trimmingTrailingLineBreaks(text)
    }

    func test_midDictationBreakSurvivesInsertion() {
        for mode in [PunctuationMode.hybrid, .spoken] {
            XCTAssertEqual(inserted("first part new line comma second part", mode),
                           "first part\nsecond part")
            XCTAssertEqual(inserted("first part new paragraph comma second part", mode),
                           "first part\n\nsecond part")
            XCTAssertEqual(inserted("first part new line period second part", mode),
                           "first part.\nSecond part")
            XCTAssertEqual(inserted("first part comma new line second part", mode),
                           "first part,\nsecond part")
        }
    }

    func test_trailingBreakIsDroppedAtInsertion() {
        for mode in [PunctuationMode.hybrid, .spoken] {
            XCTAssertEqual(inserted("first part new line comma", mode), "first part")
            XCTAssertEqual(inserted("first part new line period", mode), "first part.")
            XCTAssertEqual(inserted("first part period new line", mode), "first part.")
        }
    }
}
