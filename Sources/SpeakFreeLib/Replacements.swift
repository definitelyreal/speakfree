import Foundation

/// The user's "when it hears this, write that" rules, prepared for matching.
///
/// A trigger is one or more words; it matches whole words only, ignoring case and any
/// punctuation between its words. Text is scanned once, the longest trigger at each
/// position wins, and replaced text is never scanned again, so rules cannot chain or
/// loop. Each position costs a few hash lookups, so a pass scales with the length of
/// the dictation and not with the number of rules.
public struct Replacements {
    public struct Segment: Equatable {
        public let text: String
        public let isReplacement: Bool
        /// The replacement was written exactly as the user typed it (not capitalised
        /// here for a sentence start), so later case adjustment must leave it alone.
        public let isVerbatim: Bool
    }

    public static let none = Replacements([:])

    /// The longest trigger worth supporting; longer ones are ignored.
    static let maxTriggerWords = 6
    /// Punctuation and spacing allowed between two words of a trigger ("wag, one").
    private static let maxGap = 3

    private let rules: [String: String]
    private let firstWords: Set<Substring>
    private let longest: Int

    public init(_ map: [String: String]) {
        var rules: [String: String] = [:]
        var firstWords: Set<Substring> = []
        var longest = 0
        for (trigger, replacement) in map {
            let words = Self.words(in: trigger)
            guard !words.isEmpty, words.count <= Self.maxTriggerWords else { continue }
            let key = words.joined(separator: " ")
            rules[key] = replacement
            firstWords.insert(Substring(words[0]))
            longest = max(longest, words.count)
        }
        self.rules = rules
        self.firstWords = firstWords
        self.longest = longest
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// A trigger as it is stored and matched: lowercase words separated by single spaces.
    public static func normalize(_ trigger: String) -> String {
        words(in: trigger).joined(separator: " ")
    }

    public func apply(to text: String) -> String {
        guard !isEmpty else { return text }
        return segments(of: text).map(\.text).joined()
    }

    public func segments(of text: String) -> [Segment] {
        guard !isEmpty, !text.isEmpty else {
            return text.isEmpty ? [] : [Segment(text: text, isReplacement: false, isVerbatim: false)]
        }
        let tokens = Self.tokens(in: text)
        var segments: [Segment] = []
        var copiedUpTo = text.startIndex
        var index = 0
        while index < tokens.count {
            guard firstWords.contains(Substring(tokens[index].lower)),
                  let match = longestMatch(at: index, tokens: tokens, text: text) else {
                index += 1
                continue
            }
            let start = tokens[index].range.lowerBound
            let end = tokens[index + match.count - 1].range.upperBound
            if copiedUpTo < start {
                segments.append(Segment(text: String(text[copiedUpTo..<start]),
                                        isReplacement: false, isVerbatim: false))
            }
            let capitalise = Self.startsSentence(text, at: start)
                && match.replacement == match.replacement.lowercased()
                && match.replacement.first?.isLetter == true
            segments.append(Segment(
                text: capitalise
                    ? match.replacement.prefix(1).uppercased() + match.replacement.dropFirst()
                    : match.replacement,
                isReplacement: true, isVerbatim: !capitalise))
            copiedUpTo = end
            index += match.count
        }
        if copiedUpTo < text.endIndex {
            segments.append(Segment(text: String(text[copiedUpTo...]),
                                    isReplacement: false, isVerbatim: false))
        }
        return segments
    }

    // MARK: - Matching

    private struct Token {
        let range: Range<String.Index>
        let lower: String
    }

    private func longestMatch(at index: Int, tokens: [Token], text: String)
        -> (count: Int, replacement: String)? {
        // How many following words can belong to one trigger: they must sit close together.
        var reach = 1
        while reach < longest, index + reach < tokens.count,
              Self.isShortGap(text[tokens[index + reach - 1].range.upperBound..<tokens[index + reach].range.lowerBound]) {
            reach += 1
        }
        var count = reach
        while count >= 1 {
            let key = count == 1
                ? tokens[index].lower
                : tokens[index..<index + count].map(\.lower).joined(separator: " ")
            if let replacement = rules[key] { return (count, replacement) }
            count -= 1
        }
        return nil
    }

    private static func isShortGap(_ gap: Substring) -> Bool {
        var length = 0
        for character in gap {
            if character.isNewline { return false }
            length += 1
            if length > maxGap { return false }
        }
        return true
    }

    /// True when nothing but spacing separates `index` from the start of the text or
    /// from the end of the previous sentence.
    private static func startsSentence(_ text: String, at index: String.Index) -> Bool {
        var cursor = index
        while cursor > text.startIndex {
            let previous = text[text.index(before: cursor)]
            if previous.isNewline { return true }
            if previous == " " || previous == "\t" {
                cursor = text.index(before: cursor)
                continue
            }
            return previous == "." || previous == "!" || previous == "?" || previous == "\u{2026}"
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    private static func tokens(in text: String) -> [Token] {
        var tokens: [Token] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if isWordCharacter(text[index]) {
                if start == nil { start = index }
            } else if let wordStart = start {
                tokens.append(Token(range: wordStart..<index, lower: text[wordStart..<index].lowercased()))
                start = nil
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            tokens.append(Token(range: wordStart..<text.endIndex, lower: text[wordStart...].lowercased()))
        }
        return tokens
    }

    private static func words(in text: String) -> [String] {
        tokens(in: text).map(\.lower)
    }
}
