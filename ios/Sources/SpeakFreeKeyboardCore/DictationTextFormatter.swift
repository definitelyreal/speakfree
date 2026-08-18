// ai-suggestion:unverified · session:01a00cac-80fe-7e81-ad7f-32c2599da24d · 2026-08-17

import Foundation

public enum DictationCapitalizationPolicy: String, Equatable, Sendable {
    case none
    case sentences
    case words
    case allCharacters
}

/// Applies only casing that the host field's text-input traits make deterministic. It deliberately
/// preserves every other model character: proper-noun recovery and punctuation require a measured
/// language model, while sentence starts and all-caps fields can be fixed without guessing.
public enum DictationTextFormatter {
    public static func format(
        _ text: String,
        contextBeforeInput: String,
        capitalization: DictationCapitalizationPolicy
    ) -> String {
        guard !text.isEmpty else { return text }
        switch capitalization {
        case .none:
            return text
        case .allCharacters:
            return text.uppercased()
        case .words:
            return capitalizeWords(text, after: contextBeforeInput)
        case .sentences:
            return capitalizeSentences(text, after: contextBeforeInput)
        }
    }

    private static func capitalizeSentences(_ text: String, after context: String) -> String {
        var needsCapital = startsSentence(after: context)
        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if needsCapital, character.isLetter {
                if wordHasInternalUppercase(characters, startingAt: index) {
                    result.append(character)
                } else {
                    result.append(contentsOf: character.uppercased())
                }
                needsCapital = false
            } else {
                result.append(character)
            }
            if sentenceTerminators.contains(character) {
                needsCapital = true
            } else if character.isLetter || character.isNumber {
                needsCapital = false
            }
        }
        return result
    }

    private static func capitalizeWords(_ text: String, after context: String) -> String {
        var needsCapital = context.last?.isWhitespace ?? true
        var result = ""
        result.reserveCapacity(text.count)

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if needsCapital, character.isLetter {
                if wordHasInternalUppercase(characters, startingAt: index) {
                    result.append(character)
                } else {
                    result.append(contentsOf: character.uppercased())
                }
                needsCapital = false
            } else {
                result.append(character)
            }
            if character.isWhitespace {
                needsCapital = true
            } else if character.isLetter || character.isNumber {
                needsCapital = false
            }
        }
        return result
    }

    private static func startsSentence(after context: String) -> Bool {
        var remaining = context[...]
        while let last = remaining.last,
              last.isWhitespace || trailingClosers.contains(last) {
            remaining = remaining.dropLast()
        }
        guard let last = remaining.last else { return true }
        return sentenceTerminators.contains(last)
    }

    /// Brand names such as `iPhone` and `eBay` carry intentional casing from the recognizer.
    /// Uppercasing their first scalar would corrupt them into `IPhone`/`EBay`.
    private static func wordHasInternalUppercase(_ characters: [Character], startingAt index: Int) -> Bool {
        guard index + 1 < characters.count else { return false }
        for character in characters[(index + 1)...] {
            guard character.isLetter else { break }
            if character.isUppercase { return true }
        }
        return false
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
    private static let trailingClosers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
}
