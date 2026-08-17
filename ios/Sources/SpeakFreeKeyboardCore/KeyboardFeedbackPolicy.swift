// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

/// Semantic feedback events emitted by keyboard interactions. UIKit rendering stays in the
/// extension, while this mapping is deterministic and Simulator-testable.
public enum KeyboardFeedbackEvent: CaseIterable, Equatable, Sendable {
    case keyTap
    case cursorStep
    case deleteWord
    case swipeCommit
    case candidateCommit
    case alternateOpened
    case alternateChanged

    public var signal: KeyboardFeedbackSignal {
        switch self {
        case .cursorStep, .alternateChanged:
            return .selection
        case .keyTap:
            return .lightImpact(intensity: 0.45)
        case .alternateOpened:
            return .lightImpact(intensity: 0.8)
        case .deleteWord:
            return .firmImpact(intensity: 0.65)
        case .swipeCommit, .candidateCommit:
            return .firmImpact(intensity: 0.85)
        }
    }
}

public enum KeyboardFeedbackSignal: Equatable, Sendable {
    case selection
    case lightImpact(intensity: Double)
    case firmImpact(intensity: Double)
}
