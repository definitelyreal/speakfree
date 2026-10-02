// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-22

import XCTest
@testable import SpeakFreeLib

final class RecentSnapshotMergeTests: XCTestCase {
    func testRefreshKeepsInMemoryTextWhileSidecarIsStillBeingWritten() {
        let a = URL(fileURLWithPath: "/tmp/a.wav"), b = URL(fileURLWithPath: "/tmp/b.wav")
        let d = Date()
        let previous = [Recording(url: a, date: d, text: "just dictated"), Recording(url: b, date: d, text: "old")]
        let refreshed = [Recording(url: a, date: d, text: nil), Recording(url: b, date: d, text: "old, edited")]
        let merged = StatusBarController.keepingKnownText(refreshed: refreshed, previous: previous)
        XCTAssertEqual(merged.map(\.text), ["just dictated", "old, edited"])
    }

    func testUnknownTakesStayWithoutText() {
        let c = URL(fileURLWithPath: "/tmp/c.wav")
        let merged = StatusBarController.keepingKnownText(
            refreshed: [Recording(url: c, date: Date(), text: nil)], previous: [])
        XCTAssertNil(merged[0].text)
    }
}
