// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class KeyboardFeedbackPolicyTests: XCTestCase {
    func testEveryInteractionHasAnIntentionalFeedbackSignal() {
        XCTAssertEqual(KeyboardFeedbackEvent.allCases.count, 7)
        XCTAssertEqual(KeyboardFeedbackEvent.keyTap.signal, .lightImpact(intensity: 0.45))
        XCTAssertEqual(KeyboardFeedbackEvent.cursorStep.signal, .selection)
        XCTAssertEqual(KeyboardFeedbackEvent.deleteWord.signal, .firmImpact(intensity: 0.65))
        XCTAssertEqual(KeyboardFeedbackEvent.swipeCommit.signal, .firmImpact(intensity: 0.85))
        XCTAssertEqual(KeyboardFeedbackEvent.candidateCommit.signal, .firmImpact(intensity: 0.85))
        XCTAssertEqual(KeyboardFeedbackEvent.alternateOpened.signal, .lightImpact(intensity: 0.8))
        XCTAssertEqual(KeyboardFeedbackEvent.alternateChanged.signal, .selection)
    }
}
