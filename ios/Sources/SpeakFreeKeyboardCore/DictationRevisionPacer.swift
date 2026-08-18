// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation

/// Rate-limits *active* dictation revisions so a host field is not re-laid-out on every 125 ms
/// poll while words are still being revised.
///
/// A coalesced revision is never dropped: the caller leaves its applied-revision cursor untouched,
/// so the next poll re-offers the newest snapshot. Terminal revisions — and anything the user asked
/// for by tapping the relay key — bypass pacing entirely, because that text must land immediately.
public struct DictationRevisionPacer: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case apply
        case coalesce
    }

    public let minimumActiveInterval: TimeInterval
    private var lastAppliedAt: Date?

    public init(minimumActiveInterval: TimeInterval = 0.4) {
        self.minimumActiveInterval = minimumActiveInterval
    }

    public mutating func admit(
        phase: DictationSessionPhase,
        at now: Date,
        userInitiated: Bool = false
    ) -> Decision {
        guard phase == .active, !userInitiated else {
            lastAppliedAt = now
            return .apply
        }
        // A backwards clock jump must release the gate rather than stall revisions forever.
        if let lastAppliedAt {
            let elapsed = now.timeIntervalSince(lastAppliedAt)
            if elapsed >= 0, elapsed < minimumActiveInterval { return .coalesce }
        }
        lastAppliedAt = now
        return .apply
    }

    /// Called when ownership is abandoned or a new session is claimed, so the first revision of the
    /// next claim is never delayed by the previous one.
    public mutating func reset() {
        lastAppliedAt = nil
    }
}
