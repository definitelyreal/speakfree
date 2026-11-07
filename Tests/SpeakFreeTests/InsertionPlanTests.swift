import XCTest
@testable import SpeakFreeLib

final class InsertionPlanTests: XCTestCase {
    func testStayingInTheSameAppKeepsTheOriginalCursorAndSpacing() {
        let plan = FinalizePipeline.insertionPlan(
            startedIn: "com.apple.Notes", finishingIn: "com.apple.Notes", prependSpace: true)
        XCTAssertTrue(plan.returnsToOriginalElement)
        XCTAssertTrue(plan.prependSpace)
    }

    func testSwitchingAppsInsertsWhereYouAreNow() {
        let plan = FinalizePipeline.insertionPlan(
            startedIn: "com.apple.Notes", finishingIn: "com.mitchellh.ghostty", prependSpace: true)
        XCTAssertFalse(plan.returnsToOriginalElement)
        // The leading space was worked out from the text before the old cursor.
        XCTAssertFalse(plan.prependSpace)
    }

    func testAnUnknownAppAtEitherEndCountsAsASwitch() {
        XCTAssertFalse(FinalizePipeline.insertionPlan(
            startedIn: nil, finishingIn: "com.apple.Notes", prependSpace: true).returnsToOriginalElement)
        XCTAssertFalse(FinalizePipeline.insertionPlan(
            startedIn: "com.apple.Notes", finishingIn: nil, prependSpace: false).returnsToOriginalElement)
    }
}
