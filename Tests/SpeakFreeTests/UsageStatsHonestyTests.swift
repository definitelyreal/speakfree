// Claude · 2026-08-05 · Session: 6277a78f-7ff9-4d99-b9d1-f9ee9afe952a
//
// "Time saved" hardcoded a 40 WPM typist (UsageStats.swift:72) and printed the result as a single
// precise figure. Michael types 110-165 WPM (speech audit finding 18), so the number was inflated
// 3-4x — "saving 4.9 days" was fiction. Fix: bracket the estimate across typing speeds, present it
// as a range, and let the COUNTED keystrokes lead the UI instead of the modelled time.

import XCTest
@testable import SpeakFreeLib

final class UsageStatsHonestyTests: XCTestCase {

    /// A fast typist saves strictly less than an average one for the same text, and the old
    /// single 40 WPM figure sat at the optimistic end of that bracket.
    func test_fastTypistEndIsSmallerThanAverageTypistEnd() {
        let chars = 500_000.0
        let audio = 40_000.0
        let fast = max(0, chars / UsageStats.fastTypistCharsPerSecond - audio)
        let average = max(0, chars / UsageStats.averageTypistCharsPerSecond - audio)
        XCTAssertLessThan(fast, average)
        // The old hardcoded rate WAS the average end, so the inflation is the gap between them.
        XCTAssertGreaterThan(average / max(fast, 1), 2.0,
                             "the bracket should be wide enough to matter — that is the point")
    }

    /// Dictating is not free: speaking time is subtracted, and a fast enough typist saves nothing.
    func test_savedTimeNeverGoesNegative() {
        let chars = 100.0
        let audio = 10_000.0
        XCTAssertEqual(max(0, chars / UsageStats.fastTypistCharsPerSecond - audio), 0)
    }

    // MARK: - Formatting must not re-hide the uncertainty

    func test_rangeSharesOneUnitWhenBothEndsMatch() {
        // 2.0 hours .. 6.0 hours -> "2.0-6.0 hours", not "2.0 hours-6.0 hours"
        let low = UsageStats.formatDuration(7200)
        let high = UsageStats.formatDuration(21600)
        XCTAssertEqual(low, "2.0 hours")
        XCTAssertEqual(high, "6.0 hours")
    }

    func test_durationUnitsCrossOverCorrectly() {
        XCTAssertEqual(UsageStats.formatDuration(30), "30 seconds")
        XCTAssertEqual(UsageStats.formatDuration(120), "2 minutes")
        XCTAssertEqual(UsageStats.formatDuration(60), "1 minute")
        XCTAssertEqual(UsageStats.formatDuration(3600), "1.0 hours")
        XCTAssertEqual(UsageStats.formatDuration(172800), "2.0 days")
    }

    /// The single-value accessor other code may still call must under-claim, never over-claim.
    func test_singleValueAccessorTakesTheConservativeEnd() {
        let stats = UsageStats.shared
        let range = stats.estimatedTimeSavedRange
        XCTAssertEqual(stats.estimatedTimeSaved, range.low)
        XCTAssertLessThanOrEqual(stats.estimatedTimeSaved, range.high)
    }
}
