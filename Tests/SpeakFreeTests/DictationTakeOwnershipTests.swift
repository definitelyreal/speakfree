// ai-suggestion:unverified · session:unknown/agent:code_audio_bluetooth · 2026-10-01
import XCTest
@testable import SpeakFreeLib

/// Synthetic lifecycle/identity facts only: no app UI, clipboard, microphone or AX queries.
final class DictationTakeOwnershipTests: XCTestCase {
    func testOlderResultCannotBorrowTheTakeThatStartedDuringInference() {
        var ownership = TakePresentationOwnership()
        let takeA = ownership.beginTake()
        let capturedBeforeInference = ownership.current
        let takeB = ownership.beginTake()
        var history: [String] = []
        var overlay = "B recording"
        // Result retention is unconditional; presentation uses the pre-inference token.
        history.append("A result")
        if ownership.owns(capturedBeforeInference) { overlay = "hidden" }
        XCTAssertEqual(takeA, capturedBeforeInference)
        XCTAssertEqual(history, ["A result"])
        XCTAssertEqual(overlay, "B recording")
        XCTAssertTrue(ownership.owns(takeB))
    }

    func testOlderCompletionCannotIdleANewerTranscribingTake() {
        var ownership = TakePresentationOwnership()
        let takeA = ownership.beginTake()
        let takeB = ownership.beginTake()
        var status = "B transcribing"
        if ownership.owns(takeA) { status = "idle" }
        XCTAssertEqual(status, "B transcribing")
        if ownership.owns(takeB) { status = "idle" }
        XCTAssertEqual(status, "idle")
    }

    func testDelayedOlderRecoveryAndDismissalCannotReplaceNewerRecovery() {
        var ownership = TakePresentationOwnership()
        let takeA = ownership.beginTake()
        let takeB = ownership.beginTake()
        var recovery = "B manual recovery"
        if ownership.owns(takeA) { recovery = "A automatic retry" }
        if ownership.owns(takeA) { recovery = "dismissed" }
        XCTAssertEqual(recovery, "B manual recovery")
        XCTAssertTrue(ownership.owns(takeB))
    }

    func testPostBufferContinuationKeepsItsTakeOwnership() {
        var ownership = TakePresentationOwnership()
        let take = ownership.beginTake()
        // A release/resume changes the timer generation, not the recording-start identity.
        let afterRelease = ownership.current
        XCTAssertTrue(ownership.owns(take))
        XCTAssertEqual(afterRelease, take)
    }

    private func action(_ ownership: inout SecureInputRetryOwnership, pid: Int32? = 101,
                        window: Bool? = true, field: Bool? = true,
                        secure: Bool = false, moved: Bool = false)
        -> TextInserter.SecureInputRetryAction {
        let matches = ownership.observe(currentPID: pid, sameWindow: window, sameField: field)
        return TextInserter.secureInputRetryAction(secureInputActive: secure,
            clipboardMoved: moved, frontmostMatchesTarget: matches, deadlinePassed: false)
    }

    func testSecureInputClearingOnlyRetriesOriginalPIDWindowAndField() {
        var ownership = SecureInputRetryOwnership(targetPID: 101)
        XCTAssertEqual(action(&ownership, secure: true), .wait)
        XCTAssertEqual(action(&ownership), .insert)
    }

    func testSameAppDifferentFieldCannotReceiveParkedText() {
        var ownership = SecureInputRetryOwnership(targetPID: 101)
        XCTAssertEqual(action(&ownership, field: false, secure: true), .wait)
        XCTAssertEqual(action(&ownership, field: false), .wait)
        XCTAssertEqual(action(&ownership), .wait, "Returning later cannot rearm automatic retry")
    }

    func testSameAppDifferentWindowCannotReceiveParkedText() {
        var ownership = SecureInputRetryOwnership(targetPID: 101)
        XCTAssertEqual(action(&ownership, window: false), .wait)
        XCTAssertEqual(action(&ownership), .wait)
    }

    func testRelaunchedSameBundleCannotReceiveParkedText() {
        var ownership = SecureInputRetryOwnership(targetPID: 101)
        XCTAssertEqual(action(&ownership, pid: 202), .wait)
        XCTAssertEqual(action(&ownership), .wait)
    }

    func testUnknownPIDAtCaptureNeverBecomesAutomaticPermission() {
        var ownership = SecureInputRetryOwnership(targetPID: nil)
        XCTAssertEqual(action(&ownership, pid: nil), .wait)
        XCTAssertEqual(action(&ownership), .wait)
    }

    func testUnknownObservationRevokesRetryEvenIfLaterReadsRecover() {
        for unknown in 0..<3 {
            var ownership = SecureInputRetryOwnership(targetPID: 101)
            XCTAssertEqual(action(&ownership, pid: unknown == 0 ? nil : 101,
                                  window: unknown == 1 ? nil : true,
                                  field: unknown == 2 ? nil : true), .wait)
            XCTAssertEqual(action(&ownership), .wait)
        }
    }

    func testClipboardReplacementStillDismissesRevokedRetry() {
        var ownership = SecureInputRetryOwnership(targetPID: 101)
        XCTAssertEqual(action(&ownership, field: false), .wait)
        XCTAssertEqual(action(&ownership, moved: true), .dismiss)
    }
}

final class ManualInsertionRecoveryTests: XCTestCase {
    func testNewTakeWhileModalIsOpenCannotCopyOlderText() {
        var valid = true
        TextInserter.runManualRecovery(shouldPresent: { valid }, present: { _ in
            valid = false
            return true
        }, copy: { XCTFail("Ownership changed while modal was open"); return true })
    }
    func testFailedCopyKeepsRecoveryUntilExplicitClose() {
        var failuresShown: [Bool] = []
        var copies = 0
        TextInserter.runManualRecovery(shouldPresent: { true }, present: { failed in
            failuresShown.append(failed)
            return failuresShown.count == 1 // Copy, then Close after seeing failure.
        }, copy: { copies += 1; return false })
        XCTAssertEqual(failuresShown, [false, true])
        XCTAssertEqual(copies, 1)
    }

    func testSuccessfulCopyCompletesWithoutFailurePresentation() {
        var shown: [Bool] = []
        var copies = 0
        TextInserter.runManualRecovery(shouldPresent: { true }, present: {
            shown.append($0); return true
        }, copy: { copies += 1; return true })
        XCTAssertEqual(shown, [false])
        XCTAssertEqual(copies, 1)
    }

    func testStaleTakeNeverPresentsOrCopies() {
        var ownership = TakePresentationOwnership()
        let takeA = ownership.beginTake()
        ownership.beginTake()
        TextInserter.runManualRecovery(shouldPresent: { ownership.owns(takeA) },
            present: { _ in XCTFail("Stale take must not present"); return true },
            copy: { XCTFail("No explicit copy choice"); return false })
    }

    func testNewTakeBetweenFailedCopyAndRetrySuppressesOldDialog() {
        var ownership = TakePresentationOwnership()
        let takeA = ownership.beginTake()
        var presentations = 0
        TextInserter.runManualRecovery(shouldPresent: { ownership.owns(takeA) },
            present: { _ in presentations += 1; return true },
            copy: { ownership.beginTake(); return false })
        XCTAssertEqual(presentations, 1)
    }

    func testCloseDoesNotTouchClipboard() {
        TextInserter.runManualRecovery(shouldPresent: { true },
            present: { _ in false }, copy: { XCTFail("Close is not Copy"); return false })
    }
}
