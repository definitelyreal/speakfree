// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16
import UIKit

enum KeyboardKey: Equatable {
    case character(String)
    case shift
    case delete
    case globe
    case mode
    case space
    case returnKey
    case punctuation(String)

    var label: String {
        switch self {
        case .character(let value), .punctuation(let value): value
        case .shift: "⇧"
        case .delete: "⌫"
        case .globe: "🌐"
        case .mode: "123"
        case .space: "space"
        case .returnKey: "return"
        }
    }

    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }
}

struct PositionedKey {
    let key: KeyboardKey
    let frame: CGRect
}
