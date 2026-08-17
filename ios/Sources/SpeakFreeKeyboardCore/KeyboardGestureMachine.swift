// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

public enum KeyboardGestureRole: Equatable, Sendable {
    case character
    case disabledCharacter
    case space
    case delete
    case other
}

public enum KeyboardGestureState: Equatable, Sendable {
    case idle
    case tapPending
    case swiping
    case cursorMoving
    case deleteWord
    case deleteRepeating
    case selectingAlternate
    case suppressed
}

public enum KeyboardGestureAction: Equatable, Sendable {
    case moveCursor(Int)
    case deleteWord
    case previewSwipe
}

public enum KeyboardGestureOutcome: Equatable, Sendable {
    case tap
    case commitSwipe
    case selectedAlternate
    case none
}

/// Exclusive gesture classifier shared by UIKit and deterministic path replay tests.
public struct KeyboardGestureMachine: Equatable, Sendable {
    public private(set) var state: KeyboardGestureState = .idle
    public private(set) var role: KeyboardGestureRole = .other
    public private(set) var sampleCount = 0

    private var initialX: Double = 0
    private var initialY: Double = 0
    private var cursorSteps = 0
    private var lastPreviewTimestamp: TimeInterval = 0

    public init() {}

    public mutating func begin(
        role: KeyboardGestureRole,
        x: Double,
        y: Double,
        timestamp: TimeInterval
    ) {
        self.role = role
        state = .tapPending
        initialX = x
        initialY = y
        cursorSteps = 0
        sampleCount = 1
        lastPreviewTimestamp = timestamp
    }

    public mutating func move(
        x: Double,
        y: Double,
        timestamp: TimeInterval
    ) -> [KeyboardGestureAction] {
        guard state != .idle else { return [] }
        sampleCount += 1
        guard state != .selectingAlternate else { return [] }

        let dx = x - initialX
        let dy = y - initialY
        let distance = hypot(dx, dy)

        if state == .tapPending,
           role == .space,
           abs(dx) >= 12,
           abs(dx) > abs(dy) * 1.5 {
            state = .cursorMoving
        } else if state == .tapPending,
                  role == .delete,
                  dx < -28,
                  abs(dx) > abs(dy) * 1.25 {
            state = .deleteWord
            return [.deleteWord]
        } else if state == .tapPending,
                  role == .character,
                  distance >= 18 {
            state = .swiping
        } else if state == .tapPending,
                  role == .disabledCharacter,
                  distance >= 18 {
            state = .suppressed
        }

        if state == .cursorMoving {
            let steps = Int(dx / 12)
            guard steps != cursorSteps else { return [] }
            defer { cursorSteps = steps }
            return [.moveCursor(steps - cursorSteps)]
        }

        if state == .swiping,
           timestamp - lastPreviewTimestamp >= 0.12,
           sampleCount >= 4 {
            lastPreviewTimestamp = timestamp
            return [.previewSwipe]
        }
        return []
    }

    public mutating func beginAlternateSelection() -> Bool {
        guard state == .tapPending else { return false }
        state = .selectingAlternate
        return true
    }

    public mutating func beginDeleteRepeating() -> Bool {
        guard role == .delete,
              state == .tapPending || state == .deleteRepeating else { return false }
        state = .deleteRepeating
        return true
    }

    public mutating func end(hasSelectedAlternate: Bool = false) -> KeyboardGestureOutcome {
        let outcome: KeyboardGestureOutcome
        switch state {
        case .tapPending: outcome = .tap
        case .swiping where sampleCount >= 3: outcome = .commitSwipe
        case .selectingAlternate where hasSelectedAlternate: outcome = .selectedAlternate
        default: outcome = .none
        }
        reset()
        return outcome
    }

    public mutating func cancel() { reset() }

    private mutating func reset() {
        state = .idle
        role = .other
        sampleCount = 0
        cursorSteps = 0
    }
}
