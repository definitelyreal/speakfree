// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class CandidateReplacementTests: XCTestCase {
    func testReplacesOnlyTheExactOwnedSuffix() {
        let committed = CommittedCandidate(text: "computer")

        XCTAssertEqual(
            committed.replacementEdit(with: "computers", before: "a computer "),
            TypingEdit(deleteBackwardCount: 9, insertion: "computers ")
        )
        XCTAssertNil(committed.replacementEdit(with: "computers", before: "a commuter "))
        XCTAssertNil(committed.replacementEdit(with: "computers", before: "a computer"))
        XCTAssertNil(committed.replacementEdit(with: "computers", before: nil))
    }

    func testUnicodeReplacementCountsGraphemesRatherThanCodeUnits() {
        let committed = CommittedCandidate(text: "café")
        XCTAssertEqual(
            committed.replacementEdit(with: "cafés", before: "un café "),
            TypingEdit(deleteBackwardCount: 5, insertion: "cafés ")
        )
    }

    func testSelectingTheAlreadyCommittedCandidateIsANoOp() {
        let committed = CommittedCandidate(text: "hello")
        XCTAssertEqual(
            committed.replacementEdit(with: "hello", before: "hello "),
            TypingEdit.none
        )
    }

    func testFirstBackspaceCanRemoveAnUnchangedSwipeCommitAtomically() {
        let committed = CommittedCandidate(text: "computer")
        XCTAssertEqual(
            committed.removalEdit(before: "a computer "),
            TypingEdit(deleteBackwardCount: 9)
        )
        XCTAssertNil(committed.removalEdit(before: "a computer lab "))
    }
}
