// ai-suggestion:unverified · session:01a0f5ce-3321-7bd1-9738-1f28ad96ef6b · 2026-10-02
import XCTest
@testable import SpeakFreeLib

final class DictationRecoveryQueueTests: XCTestCase {
    func testFailedOlderTakeWaitsThroughNewerTakeAndRevokedDialogWithoutLosingText() {
        let queue = DictationRecoveryQueue()
        var work: [() -> Void] = []
        var busy = true
        var shown: [String] = []
        var completions: [(Bool) -> Void] = []
        queue.schedule = { work.append($0) }
        queue.isAvailable = { !busy }
        queue.present = { text, allowed, completed in
            XCTAssertTrue(allowed()); shown.append(text); completions.append(completed)
        }
        queue.retain("Older failed take")
        work.removeFirst()()
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(queue.hasPending)
        busy = false
        work.removeFirst()()
        XCTAssertEqual(shown, ["Older failed take"])
        queue.retain("Second failed take")
        XCTAssertTrue(work.isEmpty, "Never stack dialogs")
        busy = true
        completions.removeFirst()(false) // New take revoked Copy while modal was open.
        work.removeFirst()()
        XCTAssertEqual(shown.count, 1)
        busy = false
        work.removeFirst()()
        XCTAssertEqual(shown, ["Older failed take", "Older failed take"])
        completions.removeFirst()(true) // Explicit Close or successful Copy acknowledges it.
        work.removeFirst()()
        XCTAssertEqual(shown.last, "Second failed take")
        completions.removeFirst()(true)
        XCTAssertFalse(queue.hasPending)
        XCTAssertTrue(work.isEmpty)
    }

    func testBackpressureNeverDiscardsAlreadyInFlightText() {
        let queue = DictationRecoveryQueue()
        var work: [() -> Void] = []
        queue.schedule = { work.append($0) }
        var shown: [String] = []
        queue.isAvailable = { true }
        queue.present = { text, _, finished in shown.append(text); finished(true) }
        for i in 0..<8 { queue.retain("Result \(i)") }
        XCTAssertTrue(queue.blocksNewCapture)
        queue.retain("Already in flight")
        while !work.isEmpty { work.removeFirst()() }
        XCTAssertEqual(shown, (0..<8).map { "Result \($0)" } + ["Already in flight"])
        XCTAssertFalse(queue.blocksNewCapture)
    }

    func testRevokedCopyIsNotAcknowledgedButExplicitCloseIs() {
        var allowed = true
        XCTAssertFalse(TextInserter.runManualRecovery(shouldPresent: { allowed }, present: { _ in
            allowed = false; return true
        }, copy: { XCTFail("No stale copy"); return true }))
        XCTAssertTrue(TextInserter.runManualRecovery(shouldPresent: { true },
            present: { _ in false }, copy: { XCTFail("Close does not copy"); return true }))
    }
}
