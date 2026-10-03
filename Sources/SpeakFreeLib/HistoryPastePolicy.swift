// ai-suggestion:unverified · session:unknown/agent:code_audio_bluetooth · 2026-10-03
import AppKit

/// Explicit History selection permits an opaque field in a confirmed original window.
/// It does not relax the destination policy for delayed dictation or Edit delivery.
enum HistoryPastePolicy {
    struct Observation {
        var sameWindow: Bool?
        var sameField: Bool?
        var sameTitle: Bool?
    }
    enum Refusal: String {
        case appChanged, windowUnknown, windowChanged, fieldChangedOrUnknown, titleChanged
        case cancelled, busy, secureInput, clipboardChanged
    }

    static func refusal(capturedWindow: Bool, capturedField: Bool,
                        observation: Observation) -> Refusal? {
        guard capturedWindow, let sameWindow = observation.sameWindow else { return .windowUnknown }
        guard sameWindow else { return .windowChanged }
        if capturedField && observation.sameField != true { return .fieldChangedOrUnknown }
        // Window identity is mandatory. A readable, affirmative title change adds a veto;
        // apps that omit a title do not lose the explicit-paste action for that reason alone.
        if observation.sameTitle == false { return .titleChanged }
        return nil
    }

    static func finalRefusal(operationMatches: Bool, frontmostMatches: Bool, busy: Bool,
                             secureInput: Bool, clipboardMatches: Bool) -> Refusal? {
        if !operationMatches { return .cancelled }
        if !frontmostMatches { return .appChanged }
        if busy { return .busy }
        if secureInput { return .secureInput }
        if !clipboardMatches { return .clipboardChanged }
        return nil
    }

    /// Only new presses/scrolls invalidate a hidden operation. Release events from the
    /// opening shortcut/selection and speakfree's tagged synthetic paste are not new intent.
    static func cancelsHiddenOperation(type: NSEvent.EventType, timestamp: TimeInterval,
                                       beganAt: TimeInterval, sourcePID: Int64?, userData: Int64?,
                                       ownPID: Int64 = Int64(getpid())) -> Bool {
        guard timestamp > beganAt,
              [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type),
              sourcePID != ownPID, userData != SyntheticEventMarker.userData else { return false }
        return true
    }
}
