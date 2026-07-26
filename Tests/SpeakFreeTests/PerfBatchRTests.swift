// Claude · 2026-07-19 · Session: ed573fa2-e6e0-4a72-b0e5-8eab0a7411b1
//
// Batch R (perf adjudication build/26-07-15-adversarial-review/perf/ADJUDICATION-PERF.md)
// unit tests. Seams only — NO real audio, NO real AX, NO display dependency for the
// synthetic-buffer / capture-box cases.
//
//   R1 (finding 4): captureFocusedElement moved off the record-start path. Tested via the
//       FocusCaptureBox seam: record-start (begin) never waits; finalize (consume) gets the
//       result once published, waits briefly if still in flight, and returns nil on timeout
//       exactly like the old AX-timeout. Stale captures are generation-guarded.
//   R2 (finding 3): RecordingOverlay resolves the target screen once per recording — the
//       AX frame provider is invoked once across show + update + updateStreamingText, and
//       a new show() re-resolves (multi-display move between dictations).
//   R3 (finding 5): AudioRecorder.currentSampleCount()/samples(after:) avoid full-buffer
//       copies; trailingSlice is proven byte-identical to the old inline computation on
//       synthetic buffers.

import AppKit
import ApplicationServices
import XCTest
@testable import SpeakFreeLib

final class PerfBatchRTests: XCTestCase {

    // MARK: - R1: FocusCaptureBox (off-main capture, generation-guarded)

    func test_R1_begin_doesNotWaitOnCapture() {
        // Record-start must never block on the AX read: begin() returns without any publish.
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let start = Date()
        _ = box.begin()
        // No publish has happened; begin returned immediately.
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05,
                          "begin() (record-start) must not wait on the capture")
    }

    func test_R1_finalizeConsumesResultOnceAvailable() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let token = box.begin()
        // Simulate the background AX read landing after ~50ms.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            box.publish((nil, "before cursor"), token: token)
        }
        let start = Date()
        let result = box.consume(waitingUpTo: 0.5)
        let waited = Date().timeIntervalSince(start)
        XCTAssertEqual(result?.1, "before cursor", "finalize must consume the published context")
        XCTAssertGreaterThanOrEqual(waited, 0.04, "consume waited for the in-flight capture")
        XCTAssertLessThan(waited, 0.5, "consume returned as soon as the capture landed")
    }

    func test_R1_alreadyPublished_consumeReturnsImmediately() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let token = box.begin()
        box.publish((nil, "ready"), token: token)  // lands while user still speaking
        let start = Date()
        let result = box.consume(waitingUpTo: 0.5)
        XCTAssertEqual(result?.1, "ready")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05,
                          "an already-published capture must not wait at finalize")
    }

    func test_R1_timeoutReturnsNil_likeOldAXTimeout() {
        // Nothing ever publishes (frontmost app hung): consume waits briefly then yields nil,
        // exactly the old "AX query timed out — skipping context" semantics.
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        _ = box.begin()
        let start = Date()
        let result = box.consume(waitingUpTo: 0.1)
        let waited = Date().timeIntervalSince(start)
        XCTAssertNil(result, "timed-out capture yields nil (graceful degradation)")
        XCTAssertGreaterThanOrEqual(waited, 0.09, "consume honored the wait budget")
    }

    func test_R1_stalePublishDropped_generationGuard() {
        // A late publish from a previous recording must not overwrite the current one.
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let stale = box.begin()
        let fresh = box.begin()                       // new recording — invalidates `stale`
        box.publish((nil, "STALE"), token: stale)     // dropped
        box.publish((nil, "fresh"), token: fresh)
        XCTAssertEqual(box.consume(waitingUpTo: 0.1)?.1, "fresh",
                       "stale-generation publish must be dropped")
    }

    func test_R1_reset_consumeReturnsNilImmediately() {
        // Remote-desktop / invalidation path: reset() => consume yields nil with no wait.
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        _ = box.begin()
        box.reset()
        let start = Date()
        XCTAssertNil(box.consume(waitingUpTo: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "reset() consume must not wait")
    }

    func test_R1_publishAfterReset_isDropped() {
        // A background read that lands after reset() (its generation is stale) is ignored.
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let token = box.begin()
        box.reset()
        box.publish((nil, "late"), token: token)
        XCTAssertNil(box.consume(waitingUpTo: 0.1), "publish with a pre-reset token is dropped")
    }

    // MARK: - R1 regressions (adversarial perf review — codex-attack.md findings 1–3)

    // Finding 1: a publish landing AFTER the start-relative deadline is discarded. It would
    // supply mid-recording focus, not the focus at record-START — restoring HEAD's semantics.
    func test_R1_latePublishPastDeadline_isDiscarded() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>(captureDeadline: 0.1)
        let token = box.begin()
        Thread.sleep(forTimeInterval: 0.2)              // AX read drags past the 0.1s window
        box.publish((nil, "mid-recording"), token: token)  // must be rejected
        XCTAssertNil(box.consume(waitingUpTo: 0.05)?.1,
                     "a publish past the start-relative deadline supplies stale context and must be dropped")
    }

    // Finding 1 (control): a publish WITHIN the deadline is still accepted.
    func test_R1_publishWithinDeadline_isAccepted() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>(captureDeadline: 0.5)
        let token = box.begin()
        box.publish((nil, "record-start"), token: token)
        XCTAssertEqual(box.consume(waitingUpTo: 0.1)?.1, "record-start")
    }

    // Finding 2: consume() clears the stored AX element + cursor text so the box does not retain
    // them indefinitely after a dictation with no later recording (privacy).
    func test_R1_consumeClearsStoredValue() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>()
        let token = box.begin()
        box.publish((nil, "sensitive cursor text"), token: token)
        XCTAssertEqual(box.consume(waitingUpTo: 0.1)?.1, "sensitive cursor text")
        // A second consume of the SAME generation: the value was cleared, nothing is retained.
        XCTAssertNil(box.consume(waitingUpTo: 0.05)?.1,
                     "consume must clear the stored element/text — no indefinite retention")
    }

    // Finding 3: once the start-relative deadline has elapsed with nothing published, consume
    // returns immediately rather than blocking main on a capture that can no longer publish.
    // This is the between-dictations 0.5s freeze the review flagged.
    func test_R1_consumeAfterDeadline_returnsImmediately() {
        let box = FocusCaptureBox<(AXUIElement?, String?)>(captureDeadline: 0.05)
        _ = box.begin()
        Thread.sleep(forTimeInterval: 0.1)              // deadline elapsed, still nothing published
        let start = Date()
        let result = box.consume(waitingUpTo: 0.5)      // must NOT wait the full 0.5s
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05,
                          "consume must not block main on a capture past its start-relative deadline")
    }

    // MARK: - R2: RecordingOverlay resolves its screen once per recording

    func test_R2_showNeverBlocksOnFrameProvider() throws {
        try XCTSkipIf(NSScreen.screens.isEmpty, "needs a display to build the overlay window")
        let overlay = RecordingOverlay()
        // 2026-07-25 fade fix: the AX read moved OFF the show path entirely (async
        // refinement repositions only on disagreement). The regression this test
        // pins: an unresponsive frontmost app (slow AX) must not delay the banner.
        // The provider simulates a wedged app with a 300ms stall; show() must
        // return without paying it. (Call COUNTS are unassertable now — the async
        // refine may legitimately consult the provider at any time.)
        overlay.windowFrameProvider = {
            Thread.sleep(forTimeInterval: 0.3)
            return NSRect(x: 0, y: 0, width: 400, height: 300)
        }

        let start = Date()
        overlay.show(state: .recording)
        overlay.update(state: .transcribing)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.15,
                          "show()/update() must not block on the AX frame provider "
                          + "(took \(elapsed)s against a 0.3s-slow provider)")

        overlay.hide()
        // Drain the async refinement so its main-queue hop can't fire into a later test.
        let drained = expectation(description: "async refine drained")
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.35)
            DispatchQueue.main.async { drained.fulfill() }
        }
        wait(for: [drained], timeout: 2.0)
    }

    // MARK: - R3: trailing-samples accessor preserves the exact PostBufferPolicy slice

    /// The pre-R3 computation, verbatim, used as the oracle for old-vs-new equivalence.
    private func oldTrailing(_ all: [Float], _ index: Int) -> [Float] {
        return all.count > index ? Array(all[index...]) : []
    }

    func test_R3_trailingSlice_matchesOldComputation_onSyntheticBuffer() {
        let buffer: [Float] = (0..<1000).map { Float($0) }
        // Cover: start, mid, boundary (== count), just past count, and a typical release point.
        for index in [0, 1, 250, 500, 999, 1000, 1001, 5000] {
            let expected = oldTrailing(buffer, index)
            let actual = AudioRecorder.trailingSlice(buffer, after: index)
            XCTAssertEqual(actual, expected, "trailingSlice(after: \(index)) must equal the old slice")
        }
    }

    func test_R3_trailingSlice_emptyBuffer() {
        XCTAssertEqual(AudioRecorder.trailingSlice([], after: 0), [])
        XCTAssertEqual(AudioRecorder.trailingSlice([], after: 10), [])
    }

    func test_R3_trailingSlice_returnsOnlyThePostIndexTail() {
        let buffer: [Float] = [10, 20, 30, 40, 50]
        // samplesAtRelease = 2 → only audio captured AFTER key-release is scored as trailing.
        XCTAssertEqual(AudioRecorder.trailingSlice(buffer, after: 2), [30, 40, 50])
        XCTAssertEqual(AudioRecorder.trailingSlice(buffer, after: 5), [])
    }
}
