// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-16

import Foundation

public enum SwipeTextRenderer {
    public static func render(
        _ word: String,
        capitalization: TypingCapitalizationIntent
    ) -> String {
        switch capitalization {
        case .capsLocked:
            return word.uppercased()
        case .shifted, .automatic:
            guard let first = word.first else { return word }
            return first.uppercased() + word.dropFirst().lowercased()
        case .lowercase:
            return word.lowercased()
        }
    }
}
