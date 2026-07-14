// Claude · 2026-07-14 · Session: c58489fa-5c7d-451c-870d-8f4f5578ed2c
import Foundation

/// Machine-scoped developer mode (Michael, 2026-07-14).
///
/// Activated by a marker file at `~/.speakfree-dev` — deliberately OUTSIDE the config
/// directory so it survives config resets, reinstalls, updates, and the recordings
/// opt-in migration. It exists only on machines where the developer created it by
/// hand; nothing in the app or installer ever writes it.
///
/// Effects while active:
/// - recordings + transcript sidecars always save, regardless of `saveRecordings`
///   (the corpus is the dev machine's debugging instrument)
/// - the recordings notice never shows (the developer is not owed an apology)
/// - diagnostic logging is on
/// - the menu-bar title carries a "Dev" tag so a dev-mode instance is never
///   mistaken for a stock install (menu-title rule in CLAUDE.md)
public enum DevMode {

    static let markerName = ".speakfree-dev"

    /// Test seam: SPEAKFREE_DEV_MODE=1/0 overrides the marker-file check so tests
    /// and scratch app instances can force either state.
    public static var isActive: Bool {
        if let env = ProcessInfo.processInfo.environment["SPEAKFREE_DEV_MODE"] {
            return env == "1"
        }
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(markerName)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// The single read-site for "should this dictation persist to disk".
    public static func effectiveSaveRecordings(_ config: Config) -> Bool {
        isActive || (config.saveRecordings?.value ?? false)
    }
}
