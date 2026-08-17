// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation

/// Decides whether a previously initiated model transfer should recover on app relaunch.
/// An explicit cancellation always wins; a partial cache without that marker is interrupted work.
public enum ParakeetDownloadRecoveryPolicy {
    public static func shouldResume(
        downloadedBytes: Int64,
        totalBytes: Int64,
        userCancelled: Bool,
        activeTaskCount: Int
    ) -> Bool {
        downloadedBytes > 0
            && downloadedBytes < totalBytes
            && !userCancelled
            && activeTaskCount == 0
    }
}
