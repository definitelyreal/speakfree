// ai-suggestion:unverified · session:718d5e6d-50b3-4f35-9f63-485e474dadf3 · 2026-09-23

import Foundation

/// Whisper as the backup for Parakeet (the maintainer 2026-09-23): "Load Whisper as fallback for
/// errors" in Settings, plus a one-time offer to download the backup model the first time
/// Parakeet returns nothing on real speech and no backup is installed. Parakeet returns empty on
/// roughly 4% of takes (model-level, reproducible), and without the Whisper model on disk those
/// dictations are simply lost. Pure policy; the app wires it.
public enum WhisperFallback {
    /// The model every Whisper rescue runs (Transcriber hard-codes the same size).
    public static let modelSize = "large-v3-turbo"
    /// Approximate download size for the offer copy.
    public static let downloadSizeDescription = "1.6 GB"
    /// "Not Now" suppresses the offer for this long.
    public static let offerCooldown: TimeInterval = 14 * 24 * 3600

    public static func isEnabled(_ config: Config) -> Bool {
        config.whisperFallback?.value ?? true
    }

    public static func shouldOfferDownload(
        config: Config, engine: String, modelPresent: Bool, downloading: Bool, now: Date
    ) -> Bool {
        guard engine == "parakeet", !modelPresent, !downloading,
              config.whisperFallback?.value != false else { return false }
        guard let declined = config.whisperFallbackOfferDeclinedAt else { return true }
        return now.timeIntervalSince1970 - declined >= offerCooldown
    }

    /// Posted on main whenever the backup download starts, finishes, fails or is cancelled, so
    /// an open Settings window can redraw its row.
    public static let downloadStateChanged = Notification.Name("speakfree.whisperFallbackDownloadStateChanged")

    public static let offerTitle = "Didn't catch that"
    public static let offerMessage = """
        The speech model returned nothing for that dictation. speakfree can download a backup \
        model (Whisper, \(downloadSizeDescription)) that re-checks dictations like this one. \
        It can't recover this one, but it will be ready for future times. You can turn it off \
        in Settings.
        """
}
