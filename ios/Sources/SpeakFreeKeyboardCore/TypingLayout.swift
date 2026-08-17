// ai-suggestion:unverified · session:unknown · 2026-08-16

/// Platform-neutral mirror of the input contexts represented by `UIKeyboardType`.
public enum TypingKeyboardType: String, CaseIterable, Equatable, Sendable {
    case `default`
    case asciiCapable
    case numbersAndPunctuation
    case url
    case numberPad
    case phonePad
    case namePhonePad
    case emailAddress
    case decimalPad
    case twitter
    case webSearch
    case asciiCapableNumberPad
}

public enum TypingLayout: Equatable, Sendable {
    case alphabetic
    case numbersAndPunctuation
    case url
    case numeric
    case decimal
    case phone
    case nameAndPhone
    case email
    case social
    case webSearch

    public static func select(for keyboardType: TypingKeyboardType) -> TypingLayout {
        switch keyboardType {
        case .default, .asciiCapable:
            return .alphabetic
        case .numbersAndPunctuation:
            return .numbersAndPunctuation
        case .url:
            return .url
        case .numberPad, .asciiCapableNumberPad:
            return .numeric
        case .phonePad:
            return .phone
        case .namePhonePad:
            return .nameAndPhone
        case .emailAddress:
            return .email
        case .decimalPad:
            return .decimal
        case .twitter:
            return .social
        case .webSearch:
            return .webSearch
        }
    }
}
