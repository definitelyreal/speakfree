import XCTest
@testable import SpeakFreeLib

/// The C4 stale-work reducer. Every async cleanup result carries five tokens (session, segment,
/// source revision, attempt, arm); it is applied ONLY if all match the live state, and dropped
/// otherwise. Terminal session states are absorbing. This is the suite that proves a result
/// arriving after the user edited, after a newer attempt, or after commit can never clobber the
/// segment — the failure the whole revision-list design exists to prevent.
final class EditSessionReducerTests: XCTestCase {

    private let sessionID = UUID()
    private let segID = UUID()

    private func freshSession() -> EditSessionState {
        EditSessionState(id: sessionID, createdAt: Date(), updatedAt: Date())
    }

    /// Drive to a segment that is settled at "the cat" via one clean cleanup, returning the state and
    /// the revision the NEXT attempt would build on.
    private func reduce(_ state: EditSessionState, _ action: EditSessionAction)
        -> EditSessionReducer.Result {
        EditSessionReducer.reduce(state, action, now: Date())
    }

    private func currentRevisionID(_ state: EditSessionState) -> UUID {
        state.segments.first(where: { $0.id == segID })!.revisions.last!.id
    }

    private func openWithProvisional(_ text: String = "teh cat") -> EditSessionState {
        var s = freshSession()
        s = reduce(s, .beginSegment(segmentID: segID)).state
        s = reduce(s, .provisional(segmentID: segID, raw: "teh cat", pipelineText: text)).state
        return s
    }

    // MARK: - Happy path

    func testCleanResultAppliesEdits() {
        var s = openWithProvisional("teh cat")
        let sourceRev = currentRevisionID(s)
        let attempt = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: attempt, arm: "sonnet")).state
        XCTAssertEqual(s.segments[0].state, .cleaning)

        let completion = CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: sourceRev, attemptID: attempt,
            arm: "sonnet", edits: [SpanEdit(find: "teh", replace: "the", reason: "typo")])
        let r = reduce(s, .cleanupResult(completion))
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(r.state.segments[0].state, .settled)
        XCTAssertEqual(r.state.segments[0].currentText, "the cat")
        XCTAssertNil(r.state.segments[0].inFlight)
    }

    // MARK: - Token mismatches all drop

    func testWrongSessionDropped() {
        var s = openWithProvisional()
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: UUID(), segmentID: segID, sourceRevision: src, attemptID: a,
            arm: "sonnet", edits: [])))
        XCTAssertEqual(r.outcome, .dropped(.sessionMismatch))
    }

    func testUnknownSegmentDropped() {
        var s = openWithProvisional()
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: UUID(), sourceRevision: src, attemptID: a,
            arm: "sonnet", edits: [])))
        XCTAssertEqual(r.outcome, .dropped(.segmentMissing))
    }

    func testStaleRevisionDropped() {
        var s = openWithProvisional()
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: UUID(), attemptID: a,
            arm: "sonnet", edits: [])))
        XCTAssertEqual(r.outcome, .dropped(.staleRevision))
    }

    func testArmMismatchDropped() {
        var s = openWithProvisional()
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: src, attemptID: a,
            arm: "opus", edits: [])))
        XCTAssertEqual(r.outcome, .dropped(.armMismatch))
    }

    // MARK: - User edit always wins

    func testResultAfterUserEditDropped() {
        var s = openWithProvisional("teh cat")
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        s = reduce(s, .userEdit(segmentID: segID, newText: "my own words")).state
        XCTAssertEqual(s.segments[0].state, .edited)

        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: src, attemptID: a,
            arm: "sonnet", edits: [SpanEdit(find: "teh", replace: "the", reason: "x")])))
        XCTAssertEqual(r.outcome, .dropped(.notCleaning))
        XCTAssertEqual(r.state.segments[0].currentText, "my own words", "the user's edit stands")
    }

    // MARK: - Reordered completions + supersession

    func testLateDuplicateOfSupersededAttemptDropped() {
        var s = openWithProvisional("teh cat")
        let rev0 = currentRevisionID(s)
        let attempt1 = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: attempt1, arm: "sonnet")).state
        s = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: rev0, attemptID: attempt1,
            arm: "sonnet", edits: [SpanEdit(find: "teh", replace: "the", reason: "x")]))).state
        XCTAssertEqual(s.segments[0].currentText, "the cat")

        // A second attempt starts on the settled revision and lands.
        let rev1 = currentRevisionID(s)
        let attempt2 = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: attempt2, arm: "sonnet")).state
        s = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: rev1, attemptID: attempt2,
            arm: "sonnet", edits: [SpanEdit(find: "cat", replace: "dog", reason: "x")]))).state
        XCTAssertEqual(s.segments[0].currentText, "the dog")

        // A stale DUPLICATE of attempt1 now arrives — must be dropped, text unchanged.
        let r = reduce(s, .startCleaning(segmentID: segID, attemptID: UUID(), arm: "sonnet"))
        s = r.state
        let stale = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: rev0, attemptID: attempt1,
            arm: "sonnet", edits: [SpanEdit(find: "the", replace: "THE", reason: "x")])))
        XCTAssertEqual(stale.outcome, .dropped(.staleAttempt))
        XCTAssertEqual(stale.state.segments[0].currentText, "the dog")
    }

    // MARK: - Absorbing terminal states

    func testResultAfterCommitIgnored() {
        var s = openWithProvisional("teh cat")
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        s = reduce(s, .commit).state
        XCTAssertEqual(s.lifecycle, .committed)

        let r = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: src, attemptID: a,
            arm: "sonnet", edits: [SpanEdit(find: "teh", replace: "the", reason: "x")])))
        XCTAssertEqual(r.outcome, .ignoredTerminal)
        XCTAssertEqual(r.state.segments[0].currentText, "teh cat", "commit froze the text")
    }

    func testEveryActionAfterTerminalIsIgnored() {
        var s = openWithProvisional()
        s = reduce(s, .cancel).state
        XCTAssertEqual(s.lifecycle, .cancelled)
        for action: EditSessionAction in [
            .beginSegment(segmentID: UUID()),
            .userEdit(segmentID: segID, newText: "x"),
            .commit,
            .terminate,
        ] {
            XCTAssertEqual(reduce(s, action).outcome, .ignoredTerminal)
        }
    }

    // MARK: - Failure + retry

    func testCleanupFailedThenRetry() {
        var s = openWithProvisional()
        let a1 = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a1, arm: "sonnet")).state
        s = reduce(s, .cleanupFailed(segmentID: segID, attemptID: a1)).state
        XCTAssertEqual(s.segments[0].state, .failed)
        // A retry can start from .failed.
        let a2 = UUID()
        let r = reduce(s, .startCleaning(segmentID: segID, attemptID: a2, arm: "sonnet"))
        XCTAssertEqual(r.outcome, .applied)
        XCTAssertEqual(r.state.segments[0].state, .cleaning)
    }

    func testStaleFailureDropped() {
        var s = openWithProvisional()
        let a1 = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a1, arm: "sonnet")).state
        // A failure tagged with a different attempt id must not knock the live attempt to .failed.
        let r = reduce(s, .cleanupFailed(segmentID: segID, attemptID: UUID()))
        XCTAssertEqual(r.outcome, .dropped(.staleAttempt))
        XCTAssertEqual(r.state.segments[0].state, .cleaning)
    }

    // MARK: - Restore + bounded revisions

    func testRestoreRecoversOriginalPipelineText() {
        var s = openWithProvisional("teh cat")
        let src = currentRevisionID(s)
        let a = UUID()
        s = reduce(s, .startCleaning(segmentID: segID, attemptID: a, arm: "sonnet")).state
        s = reduce(s, .cleanupResult(CleanupCompletion(
            sessionID: sessionID, segmentID: segID, sourceRevision: src, attemptID: a,
            arm: "sonnet", edits: [SpanEdit(find: "teh", replace: "the", reason: "x")]))).state
        XCTAssertEqual(s.segments[0].currentText, "the cat")

        s = reduce(s, .restoreOriginal(segmentID: segID)).state
        XCTAssertEqual(s.segments[0].currentText, "teh cat", "restore recovers the asr text")
    }

    func testRevisionListBoundedButKeepsOriginal() {
        var s = openWithProvisional("original text")
        // Hammer many user edits; the list must stay bounded and index 0 must remain the asr original.
        for i in 0..<200 {
            s = reduce(s, .userEdit(segmentID: segID, newText: "edit \(i)")).state
        }
        let seg = s.segments[0]
        XCTAssertLessThanOrEqual(seg.revisions.count, EditSegment.maxRevisions)
        XCTAssertEqual(seg.revisions.first?.origin, .asr)
        XCTAssertEqual(seg.originalText, "original text", "restore still works after the cap kicked in")
    }
}
