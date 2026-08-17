// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import XCTest
@testable import SpeakFreeKeyboardCore

final class DictationTranscriptLedgerTests: XCTestCase {
    func testHeartbeatRefreshesLeaseWithoutChangingTranscript() throws {
        let created = Date(timeIntervalSince1970: 100)
        var ledger = DictationTranscriptLedger(createdAt: created)
        _ = try ledger.update(
            confirmedText: "Hello ",
            volatileText: "wor",
            at: created.addingTimeInterval(1)
        )

        let heartbeat = try ledger.heartbeat(at: created.addingTimeInterval(6))

        XCTAssertEqual(heartbeat.revision, 2)
        XCTAssertEqual(heartbeat.finalizedText, "Hello ")
        XCTAssertEqual(heartbeat.volatileText, "wor")
        XCTAssertEqual(heartbeat.updatedAt, created.addingTimeInterval(6))
        XCTAssertTrue(heartbeat.isFresh(at: created.addingTimeInterval(20), maximumAge: 15))
    }

    func testPromotesVolatileTextWithoutChangingFinalizedHistory() throws {
        let id = UUID()
        var ledger = DictationTranscriptLedger(sessionID: id)

        let first = try ledger.update(confirmedText: "", volatileText: "hello")
        let second = try ledger.update(confirmedText: "hello", volatileText: " world")

        XCTAssertEqual(first.renderedText, "hello")
        XCTAssertEqual(second.finalizedText, "hello")
        XCTAssertEqual(second.volatileText, " world")
        XCTAssertEqual(second.finalizedSegments.map(\.id), ["final-0"])
        XCTAssertEqual(second.revision, first.revision + 1)
    }

    func testRejectsRecognizerRegressionAfterTextWasFinalized() throws {
        var ledger = DictationTranscriptLedger()
        _ = try ledger.update(confirmedText: "hello", volatileText: " world")

        XCTAssertThrowsError(try ledger.update(confirmedText: "help", volatileText: "")) {
            XCTAssertEqual($0 as? DictationTranscriptLedgerError, .finalizedTextRegressed)
        }
    }

    func testFinishPromotesTheExactRemainingSuffix() throws {
        var ledger = DictationTranscriptLedger()
        _ = try ledger.update(confirmedText: "hello", volatileText: " wor")
        let finished = try ledger.finish(finalText: "hello world")

        XCTAssertEqual(finished.phase, .finalized)
        XCTAssertEqual(finished.finalizedText, "hello world")
        XCTAssertTrue(finished.volatileSegments.isEmpty)
    }

    func testCancelDropsOnlyVolatileText() throws {
        var ledger = DictationTranscriptLedger()
        _ = try ledger.update(confirmedText: "keep", volatileText: " discard")
        let cancelled = try ledger.cancel()

        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertEqual(cancelled.finalizedText, "keep")
        XCTAssertEqual(cancelled.volatileText, "")
    }
}
