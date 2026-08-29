import Foundation

/// Pure fn-tap reducer for Edit mode (Michael, 2026-08-28). Edit mode is TAP-driven like Toggle:
/// key-up is ignored (AppDelegate.handleKeyUp), and each fn-tap advances the session through
/// these states. Extracted as a pure function so the tap semantics are unit-testable without a
/// window, a recorder, or an AppDelegate — the same reason `TextPipeline.run` was pulled out of
/// its inline closure (drift there shipped the v1.2.11 comma loop).
///
/// Esc (cancel) and Return (commit) are WINDOW-level keys, owned by the edit window rather than the
/// hotkey, so they are deliberately absent here — the hotkey only ever advances recording posture.
public enum EditKeyReducer {

    /// The session's recording posture at the moment an fn-tap arrives.
    public enum SessionState: Equatable {
        case noSession        // no edit window open
        case recording        // a segment is currently being recorded
        case sessionOpenIdle  // window open, not recording (between segments)
    }

    /// What an fn-tap should do next.
    public enum Action: Equatable {
        case openSessionAndRecord  // open the window + start the first segment
        case endSegment            // stop the in-flight segment (settles in background)
        case startSegment          // begin an additional segment (a new paragraph)
    }

    public static func action(for state: SessionState) -> Action {
        switch state {
        case .noSession:       return .openSessionAndRecord
        case .recording:       return .endSegment
        case .sessionOpenIdle: return .startSegment
        }
    }
}
