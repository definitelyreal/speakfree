// ai-suggestion:unverified · session:unknown · 2026-08-16

import Foundation

/// A cursor-local edit that can be applied to `UITextDocumentProxy` without UIKit in this module.
public struct TypingEdit: Equatable, Sendable {
    public var deleteBackwardCount: Int
    public var insertion: String

    public init(deleteBackwardCount: Int = 0, insertion: String = "") {
        precondition(deleteBackwardCount >= 0)
        self.deleteBackwardCount = deleteBackwardCount
        self.insertion = insertion
    }

    public static let none = TypingEdit()

    /// Applies the edit to an end-of-document context. Primarily useful to hosts and tests.
    public func applying(to contextBeforeInput: String) -> String {
        var result = contextBeforeInput
        for _ in 0..<min(deleteBackwardCount, result.count) {
            result.removeLast()
        }
        result.append(insertion)
        return result
    }
}

public enum TypingCapitalizationState: Equatable, Sendable {
    case shifted
    case lowercased
}

public enum TypingCapitalizationIntent: Equatable, Sendable {
    case automatic
    case lowercase
    case shifted
    case capsLocked
}

/// Host-sensitive text behavior. Prose conveniences are intentionally disabled in address-like
/// fields where inserting a space or changing punctuation corrupts the value being entered.
public enum TypingContextPolicy: Equatable, Sendable {
    case prose
    case verbatim
    case numeric

    var usesSmartPunctuation: Bool { self == .prose }
    var usesProseSpacing: Bool { self == .prose }
    public var allowsAutocorrection: Bool { self == .prose }
}

public struct TypingComposition: Equatable, Sendable {
    public let word: String
    public let replacementLength: Int

    public init(word: String, replacementLength: Int) {
        self.word = word
        self.replacementLength = replacementLength
    }
}

public struct TypingReplacement: Equatable, Sendable {
    public let original: String
    public let accepted: String
    public let committedTrailingSpace: Bool

    public init(
        original: String,
        accepted: String,
        committedTrailingSpace: Bool = false
    ) {
        self.original = original
        self.accepted = accepted
        self.committedTrailingSpace = committedTrailingSpace
    }
}

/// Deterministic English typing behavior. The host owns the document; this value only tracks the
/// one reversible suggestion needed for the conventional "backspace to undo autocorrect" action.
public struct TypingBehaviorEngine: Equatable, Sendable {
    public private(set) var lastReplacement: TypingReplacement?

    public init() {}

    public static func capitalizationState(
        before contextBeforeInput: String
    ) -> TypingCapitalizationState {
        guard !contextBeforeInput.isEmpty else { return .shifted }
        guard let last = contextBeforeInput.last else { return .shifted }
        if last == "\n" || last == "\r" { return .shifted }
        guard last.isWhitespace else { return .lowercased }

        let trimmed = contextBeforeInput.drop(whileFromEnd: { $0.isWhitespace })
        guard let preceding = trimmed.last else { return .shifted }
        return sentenceTerminators.contains(preceding) ? .shifted : .lowercased
    }

    public static func composition(before contextBeforeInput: String) -> TypingComposition {
        let word = String(contextBeforeInput.suffix(while: isWordCharacter))
        return TypingComposition(word: word, replacementLength: word.count)
    }

    /// Produces a single-key edit, including auto-capitalization and conventional spacing rules.
    public mutating func tap(
        _ key: String,
        before contextBeforeInput: String,
        policy: TypingContextPolicy = .prose,
        capitalization: TypingCapitalizationIntent = .automatic
    ) -> TypingEdit {
        guard !key.isEmpty else { return .none }
        lastReplacement = nil

        if key == " " {
            return Self.spaceEdit(before: contextBeforeInput, policy: policy)
        }
        if key == "'" || key == "’" {
            return TypingEdit(insertion: policy.usesSmartPunctuation ? "’" : "'")
        }
        if key.count == 1, let character = key.first, Self.punctuation.contains(character) {
            return Self.punctuationEdit(character, before: contextBeforeInput, policy: policy)
        }

        var insertion = key
        if key.count == 1, key.first?.isLetter == true {
            switch capitalization {
            case .automatic:
                if Self.capitalizationState(before: contextBeforeInput) == .shifted
                    || contextBeforeInput.last.map(Self.sentenceTerminators.contains) == true {
                    insertion = key.uppercased()
                }
            case .lowercase:
                insertion = key.lowercased()
            case .shifted, .capsLocked:
                insertion = key.uppercased()
            }
        }

        if policy.usesProseSpacing,
           Self.needsLeadingSpace(before: contextBeforeInput, inserting: insertion) {
            insertion = " " + insertion
        }
        return TypingEdit(insertion: insertion)
    }

    /// Replaces the composing word and remembers the user's original input for one backspace.
    public mutating func acceptSuggestion(
        _ suggestion: String,
        before contextBeforeInput: String
    ) -> TypingEdit {
        let composition = Self.composition(before: contextBeforeInput)
        guard !composition.word.isEmpty, !suggestion.isEmpty else {
            lastReplacement = nil
            return .none
        }

        let accepted = Self.matchingCase(of: composition.word, suggestion: suggestion)
        guard accepted != composition.word else {
            lastReplacement = nil
            return .none
        }
        let original = lastReplacement.flatMap { replacement in
            replacement.accepted == composition.word ? replacement.original : nil
        } ?? composition.word
        lastReplacement = TypingReplacement(original: original, accepted: accepted)
        return TypingEdit(deleteBackwardCount: composition.replacementLength, insertion: accepted)
    }

    /// Commits the composing word and a trailing space, optionally applying an autocorrection.
    /// A correction made here remains reversible by exactly one immediately following backspace.
    public mutating func commitSpace(
        replacingWith suggestion: String?,
        before contextBeforeInput: String,
        policy: TypingContextPolicy = .prose
    ) -> TypingEdit {
        let composition = Self.composition(before: contextBeforeInput)
        guard policy.allowsAutocorrection,
              let suggestion,
              let normalizedSuggestion = Self.validWordSuggestion(suggestion),
              !composition.word.isEmpty else {
            lastReplacement = nil
            return Self.spaceEdit(before: contextBeforeInput, policy: policy)
        }

        let accepted = Self.matchingCase(
            of: composition.word,
            suggestion: normalizedSuggestion
        )
        let priorOriginal = lastReplacement.flatMap { replacement in
            !replacement.committedTrailingSpace && replacement.accepted == composition.word
                ? replacement.original
                : nil
        }

        if accepted == composition.word, priorOriginal == nil {
            lastReplacement = nil
            return Self.spaceEdit(before: contextBeforeInput, policy: policy)
        }

        lastReplacement = TypingReplacement(
            original: priorOriginal ?? composition.word,
            accepted: accepted,
            committedTrailingSpace: true
        )
        return TypingEdit(
            deleteBackwardCount: composition.replacementLength,
            insertion: accepted + " "
        )
    }

    /// Restores a just-replaced word. Otherwise this is an ordinary grapheme-safe backspace.
    public mutating func backspace(before contextBeforeInput: String) -> TypingEdit {
        defer { lastReplacement = nil }
        if let replacement = lastReplacement {
            let acceptedText = replacement.accepted + (replacement.committedTrailingSpace ? " " : "")
            guard contextBeforeInput.hasSuffix(acceptedText) else {
                return contextBeforeInput.isEmpty ? .none : TypingEdit(deleteBackwardCount: 1)
            }
            return TypingEdit(
                deleteBackwardCount: acceptedText.count,
                insertion: replacement.original
            )
        }
        return contextBeforeInput.isEmpty ? .none : TypingEdit(deleteBackwardCount: 1)
    }

    public mutating func invalidateReplacement() {
        lastReplacement = nil
    }

    /// Returns the grapheme count to remove for a word-delete gesture at the cursor.
    public static func deleteWordBackwardCount(before contextBeforeInput: String) -> Int {
        guard !contextBeforeInput.isEmpty else { return 0 }
        let characters = Array(contextBeforeInput)
        var index = characters.endIndex

        while index > characters.startIndex, characters[index - 1].isWhitespace {
            index -= 1
        }
        if index == characters.startIndex { return characters.count }

        if isWordCharacter(characters[index - 1]) {
            while index > characters.startIndex, isWordCharacter(characters[index - 1]) {
                index -= 1
            }
        } else {
            while index > characters.startIndex {
                let character = characters[index - 1]
                guard !character.isWhitespace, !isWordCharacter(character) else { break }
                index -= 1
            }
        }
        return characters.count - index
    }

    public mutating func deleteWord(before contextBeforeInput: String) -> TypingEdit {
        lastReplacement = nil
        return TypingEdit(
            deleteBackwardCount: Self.deleteWordBackwardCount(before: contextBeforeInput)
        )
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]
    private static let punctuation: Set<Character> = [".", ",", "!", "?", ":", ";"]

    private static func spaceEdit(
        before context: String,
        policy: TypingContextPolicy
    ) -> TypingEdit {
        guard !context.isEmpty else { return .none }
        guard policy == .prose else {
            return context.last?.isWhitespace == true ? .none : TypingEdit(insertion: " ")
        }
        if context.last == " " {
            let beforeFirstSpace = context.dropLast()
            if let prior = beforeFirstSpace.last,
               !prior.isWhitespace,
               !punctuation.contains(prior) {
                return TypingEdit(deleteBackwardCount: 1, insertion: ". ")
            }
            return .none
        }
        return TypingEdit(insertion: " ")
    }

    private static func punctuationEdit(
        _ punctuation: Character,
        before context: String,
        policy: TypingContextPolicy
    ) -> TypingEdit {
        guard policy.usesSmartPunctuation else {
            return TypingEdit(insertion: String(punctuation))
        }
        let trailingSpaces = context.reversed().prefix(while: { $0.isWhitespace && $0 != "\n" }).count
        return TypingEdit(deleteBackwardCount: trailingSpaces, insertion: String(punctuation))
    }

    private static func matchingCase(of original: String, suggestion: String) -> String {
        let letters = original.filter(\.isLetter)
        if !letters.isEmpty, letters.allSatisfy(\.isUppercase) {
            return suggestion.uppercased()
        }
        if original.first?.isUppercase == true {
            guard let first = suggestion.first else { return suggestion }
            return first.uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }

    private static func validWordSuggestion(_ suggestion: String) -> String? {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(isWordCharacter) else { return nil }
        return trimmed
    }

    private static func needsLeadingSpace(before context: String, inserting text: String) -> Bool {
        guard text.first?.isLetter == true, let last = context.last else { return false }
        return punctuation.contains(last)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }
}

private extension StringProtocol {
    func drop(whileFromEnd predicate: (Character) -> Bool) -> SubSequence {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard predicate(self[previous]) else { break }
            end = previous
        }
        return self[..<end]
    }

    func suffix(while predicate: (Character) -> Bool) -> SubSequence {
        var start = endIndex
        while start > startIndex {
            let previous = index(before: start)
            guard predicate(self[previous]) else { break }
            start = previous
        }
        return self[start...]
    }
}
