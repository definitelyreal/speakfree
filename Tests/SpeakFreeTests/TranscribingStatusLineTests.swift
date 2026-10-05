// ai-suggestion:unverified · session:unknown · 2026-08-21
import XCTest
@testable import SpeakFreeLib

/// The transcribing card's status line (the maintainer 2026-08-22): text centred, spinner
/// hung off its left edge, room above and below for the cymatics grains. It shows while a take
/// waits, for example on a cold model load.
final class TranscribingStatusLineTests: XCTestCase {
    static let message = "Preparing speech model\u{2026}"

    func testTranscribingStatusExpandsSpinnerPill() {
        let idleSize = OverlayContentView.pillSize(for: .transcribing)
        let statusSize = OverlayContentView.pillSize(
            for: .transcribing,
            streamingText: Self.message)
        XCTAssertGreaterThan(statusSize.width, idleSize.width)
        XCTAssertGreaterThanOrEqual(statusSize.height, idleSize.height)
    }

    /// The text centres because the pill reserves the SAME room on both sides of it
    /// (spinner + gap on the left, mirrored on the right), and the status card is
    /// tall enough to give the cymatics grains a band above and below the line.
    func testStatusPillReservesSymmetricSideRoomAndGrainBands() {
        let message = Self.message
        let textWidth = ceil((message as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        ]).width)
        let size = OverlayContentView.pillSize(for: .transcribing, streamingText: message)
        XCTAssertEqual(size.width, textWidth + OverlayContentView.statusSidePad * 2, accuracy: 0.5)
        XCTAssertEqual(size.height, OverlayContentView.statusHeight, accuracy: 1e-9)
        XCTAssertGreaterThan(OverlayContentView.statusHeight, 48, "room for grains above/below a 13pt line")
    }
}

// MARK: - Stats display helpers (the maintainer 2026-08-20 two-line format)

final class UsageStatsDisplayTests: XCTestCase {
    func testDaysHoursMinutesFormatting() {
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(59), "0 minutes")
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(3_660), "1 hour 1 minute")
        XCTAssertEqual(UsageStats.formatDaysHoursMinutes(90_000), "1 day 1 hour 0 minutes")
    }

    func testHandTravelAssumption() {
        // 2 cm per keystroke: 1M keystrokes = 20 km ≈ 12.4 miles. The constant is the
        // stated assumption; this pins it so a silent change shows up in review.
        XCTAssertEqual(UsageStats.handTravelMetresPerKeystroke, 0.02)
    }
}
