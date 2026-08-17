// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import UIKit

enum KeyboardFeedbackEvent: Equatable {
    case keyTap
    case cursorStep
    case deleteWord
    case swipeCommit
    case candidateCommit
    case alternateOpened
    case alternateChanged
}

final class KeyboardFeedbackCoordinator {
    private let selection = UISelectionFeedbackGenerator()
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let firmImpact = UIImpactFeedbackGenerator(style: .rigid)

    func prepare() {
        selection.prepare()
        lightImpact.prepare()
        firmImpact.prepare()
    }

    func emit(_ event: KeyboardFeedbackEvent) {
        switch event {
        case .cursorStep, .alternateChanged:
            selection.selectionChanged()
            selection.prepare()
        case .keyTap, .alternateOpened:
            lightImpact.impactOccurred(intensity: event == .alternateOpened ? 0.8 : 0.45)
            lightImpact.prepare()
        case .deleteWord, .swipeCommit, .candidateCommit:
            firmImpact.impactOccurred(intensity: event == .deleteWord ? 0.65 : 0.85)
            firmImpact.prepare()
        }
    }
}
