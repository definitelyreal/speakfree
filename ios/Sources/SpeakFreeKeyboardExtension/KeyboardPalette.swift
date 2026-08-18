// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import UIKit

enum KeyboardPalette {
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            : UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
    }

    static let key = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.38, green: 0.38, blue: 0.40, alpha: 1)
            : .white
    }

    static let specialKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1)
            : UIColor(red: 0.68, green: 0.71, blue: 0.75, alpha: 1)
    }

    static let pressedKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1)
            : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1)
    }

    static let pressedSpecialKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.32, green: 0.32, blue: 0.34, alpha: 1)
            : UIColor(red: 0.58, green: 0.61, blue: 0.65, alpha: 1)
    }

    /// SpeakFree's own accent. The relay key is painted with it so it can never be mistaken for
    /// the system's grey dictation control — tapping it only inserts text SpeakFree already has.
    static let relayKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.79, green: 0.20, blue: 0.24, alpha: 1)
            : UIColor(red: 0.72, green: 0.13, blue: 0.18, alpha: 1)
    }

    static let pressedRelayKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.88, green: 0.30, blue: 0.34, alpha: 1)
            : UIColor(red: 0.60, green: 0.09, blue: 0.14, alpha: 1)
    }

    static let idleRelayKey = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.30, green: 0.22, blue: 0.23, alpha: 1)
            : UIColor(red: 0.80, green: 0.72, blue: 0.74, alpha: 1)
    }

    static let separator = UIColor.separator.withAlphaComponent(0.45)
}
