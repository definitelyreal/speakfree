// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import UIKit
import SpeakFreeKeyboardCore

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
        switch event.signal {
        case .selection:
            selection.selectionChanged()
            selection.prepare()
        case .lightImpact(let intensity):
            lightImpact.impactOccurred(intensity: CGFloat(intensity))
            lightImpact.prepare()
        case .firmImpact(let intensity):
            firmImpact.impactOccurred(intensity: CGFloat(intensity))
            firmImpact.prepare()
        }
    }
}
