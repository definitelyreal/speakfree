import XCTest
@testable import SpeakFreeLib

/// The fn-tap semantics for Edit mode, and the finalize-destination routing. Both are pure so the
/// tap behavior and the "edit finalization never reaches the inserter" rule are pinned without a
/// window or an AppDelegate.
final class EditKeyReducerTests: XCTestCase {

    func testNoSessionTapOpensAndRecords() {
        XCTAssertEqual(EditKeyReducer.action(for: .noSession), .openSessionAndRecord)
    }

    func testRecordingTapEndsSegment() {
        XCTAssertEqual(EditKeyReducer.action(for: .recording), .endSegment)
    }

    func testIdleTapStartsNewSegment() {
        XCTAssertEqual(EditKeyReducer.action(for: .sessionOpenIdle), .startSegment)
    }

    // MARK: - FinalizeDestination

    func testNoEditTargetInsertsImmediately() {
        XCTAssertEqual(FinalizeDestination.resolve(editTarget: nil), .insertImmediately)
    }

    func testEditTargetReturnsToSession() {
        let sid = UUID(), segid = UUID()
        XCTAssertEqual(FinalizeDestination.resolve(editTarget: (sessionID: sid, segmentID: segid)),
                       .returnToEditSession(sessionID: sid, segmentID: segid))
    }
}
