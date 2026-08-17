// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class SwipeTextRendererTests: XCTestCase {
    func testOneShotShiftOnlyCapitalizesTheFirstGrapheme() {
        XCTAssertEqual(
            SwipeTextRenderer.render("computer", capitalization: .shifted),
            "Computer"
        )
    }

    func testCapsLockAndAllCharactersUppercaseTheWholeWord() {
        XCTAssertEqual(
            SwipeTextRenderer.render("computer", capitalization: .capsLocked),
            "COMPUTER"
        )
    }

    func testLowercaseIntentNormalizesUnexpectedModelCase() {
        XCTAssertEqual(
            SwipeTextRenderer.render("ComPuTeR", capitalization: .lowercase),
            "computer"
        )
    }
}
