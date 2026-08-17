// ai-processed:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import XCTest
@testable import SpeakFreeKeyboardCore

final class ParakeetDownloadRecoveryPolicyTests: XCTestCase {
    func testInterruptedPartialDownloadResumesOnRelaunch() {
        XCTAssertTrue(
            ParakeetDownloadRecoveryPolicy.shouldResume(
                downloadedBytes: 401_700_000,
                totalBytes: 688_651_517,
                userCancelled: false,
                activeTaskCount: 0
            )
        )
    }

    func testExplicitCancellationRemainsStopped() {
        XCTAssertFalse(
            ParakeetDownloadRecoveryPolicy.shouldResume(
                downloadedBytes: 401_700_000,
                totalBytes: 688_651_517,
                userCancelled: true,
                activeTaskCount: 0
            )
        )
    }

    func testFreshAndCompletedDownloadsDoNotRestart() {
        XCTAssertFalse(
            ParakeetDownloadRecoveryPolicy.shouldResume(
                downloadedBytes: 0,
                totalBytes: 688_651_517,
                userCancelled: false,
                activeTaskCount: 0
            )
        )
        XCTAssertFalse(
            ParakeetDownloadRecoveryPolicy.shouldResume(
                downloadedBytes: 688_651_517,
                totalBytes: 688_651_517,
                userCancelled: false,
                activeTaskCount: 0
            )
        )
    }

    func testExistingBackgroundTaskIsNotDuplicated() {
        XCTAssertFalse(
            ParakeetDownloadRecoveryPolicy.shouldResume(
                downloadedBytes: 401_700_000,
                totalBytes: 688_651_517,
                userCancelled: false,
                activeTaskCount: 1
            )
        )
    }
}
