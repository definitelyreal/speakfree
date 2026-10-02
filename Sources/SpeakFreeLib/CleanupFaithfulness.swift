// Claude · 2026-09-24 · Edit Mode V1
import Foundation

/// A meaning check on cleanup edits, separate from the structural checks in `SpanEditApplier`.
///
/// Design review (2026-09-24): exact-match replacements do NOT make rewriting impossible.
/// Replacing "do not approve" with "approve" anchors uniquely, contains no newline, and passes
/// every structural rule while reversing what was said. Structural validity and faithful cleanup
/// are different properties and each gets its own gate.
///
/// V1 rule, deliberately narrow and explainable: an edit may not change the number of negations.
/// The one exception is the discourse "no" of an obvious self-correction ("Tuesday no wait
/// Wednesday"), which is not a negation of anything and which the design asks to remove.
/// A rejected edit is logged with its cause and simply not applied; the paragraph keeps the
/// on-device text for that span.
public enum CleanupFaithfulness {

    public enum Rejection: String, Equatable {
        case negationChanged   // the edit adds or removes a negation
        case numberChanged     // the edit changes a number (digits or number words)
        case contentRemoved    // the edit deletes real words without replacing them
        case dateChanged       // the edit swaps a weekday or month for another
    }

    public struct Screened: Equatable {
        public let kept: [SpanEdit]
        public let rejected: [SpanEdit]
    }

    /// Words a repair may delete outright: garbled spoken punctuation the model turns into a mark,
    /// and fillers.
    static let removableWords: Set<String> = [
        "kama", "gamma", "comment", "comma", "commas", "karma", "paired", "period", "column",
        "colon", "semicolon", "dash", "hyphen", "quote", "unquote", "paren", "parenthesis", "dot",
        "um", "uh", "erm", "er", "ah", "hmm", "mm",
    ]

    /// Spoken punctuation commands. Their words ("new", "open", "stop", ...) are removable only as
    /// part of the whole command, never on their own.
    static let commandPhrases = [
        "new line", "new paragraph", "open paren", "close paren", "open quote", "close quote",
        "full stop", "question mark", "exclamation point", "exclamation mark",
    ]

    static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "april", "june", "july", "august", "september",
        "october", "november", "december", "today", "tomorrow", "yesterday", "tonight",
    ]

    /// Why an edit would change what was said, or nil when it is a repair.
    public static func rejection(for edit: SpanEdit) -> Rejection? {
        if negationCount(edit.find) != negationCount(edit.replace) { return .negationChanged }
        let findTokens = tokenize(edit.find)
        let replaceTokens = tokenize(edit.replace)
        // A self-correction bypass applies only when the edit REMOVES the correction marker and
        // puts in nothing he did not say ("Tuesday no wait Wednesday" -> "Wednesday"): every word
        // of the replacement must already be in the span. Not whenever a span happens to contain
        // "wait" or "actually".
        let findSet = Set(findTokens)
        // A correction also needs a false start: something said BEFORE the marker. A marker that
        // opens the span ("I mean it when I say thanks", "Actually, the report looks great") is
        // ordinary speech, and deleting the words after it is not a correction (2026-09-29 review;
        // the prompt now asks the model to drop "I mean", "sorry" and "actually" markers).
        let isCorrection = containsCorrectionMarker(findTokens) && !containsCorrectionMarker(replaceTokens)
            && replaceTokens.allSatisfy(findSet.contains)
            && (firstMarkerIndex(findTokens) ?? 0) > 0
        if isCorrection {
            // A correction keeps what he said AFTER the marker: "at 3 wait 4" may become "at 4",
            // never "at 3" (that keeps the value he took back).
            let tail = tokensAfterLastMarker(findTokens)
            let tailText = tail.joined(separator: " ")
            let tailNumbers = numbers(in: tailText)
            if numbers(in: edit.replace).contains(where: { !tailNumbers.contains($0) }) { return .numberChanged }
            if replaceTokens.contains(where: { calendarWords.contains($0) && !tail.contains($0) }) {
                return .dateChanged
            }
        }
        if !isCorrection && numbers(in: edit.find) != numbers(in: edit.replace) { return .numberChanged }
        if !isCorrection
            && findTokens.filter(calendarWords.contains).sorted()
                != replaceTokens.filter(calendarWords.contains).sorted() {
            return .dateChanged
        }
        // A pure deletion (nothing new put in its place) of real words, outside a self-correction.
        var remaining = replaceTokens
        var removed: [String] = []
        for t in findTokens {
            if let i = remaining.firstIndex(of: t) { remaining.remove(at: i) } else { removed.append(t) }
        }
        let added = remaining
        // Command words may be deleted only as many times as whole commands occur in the span:
        // "new line the new contract" may lose "new line", never the second "new".
        var commandBudget: [String: Int] = [:]
        let joinedFind = " " + findTokens.joined(separator: " ") + " "
        for phrase in commandPhrases {
            let occurrences = joinedFind.components(separatedBy: " \(phrase) ").count - 1
            guard occurrences > 0 else { continue }
            for w in phrase.split(separator: " ") { commandBudget[String(w), default: 0] += occurrences }
        }
        var deletesContent = false
        for w in removed {
            if removableWords.contains(w) || replaceTokens.contains(w) { continue }
            if let n = commandBudget[w], n > 0 { commandBudget[w] = n - 1; continue }
            deletesContent = true
        }
        if !isCorrection, added.isEmpty, deletesContent {
            return .contentRemoved
        }
        return nil
    }

    /// The words after the last correction marker in a span ("Tuesday no wait Wednesday" gives
    /// ["wednesday"]).
    private static func tokensAfterLastMarker(_ tokens: [String]) -> [String] {
        var cut = -1
        for (i, t) in tokens.enumerated() {
            for marker in correctionMarkers {
                let words = marker.split(separator: " ").map(String.init)
                if i + words.count <= tokens.count, Array(tokens[i..<(i + words.count)]) == words {
                    cut = max(cut, i + words.count - 1)
                }
            }
            if t == "no" && isDiscourseNo(at: i, in: tokens) { cut = max(cut, i) }
        }
        return cut >= 0 ? Array(tokens[(cut + 1)...]) : tokens
    }

    /// Index of the first token of the first correction marker (or discourse "no"), or nil.
    static func firstMarkerIndex(_ tokens: [String]) -> Int? {
        for (i, t) in tokens.enumerated() {
            for marker in correctionMarkers {
                let words = marker.split(separator: " ").map(String.init)
                if i + words.count <= tokens.count, Array(tokens[i..<(i + words.count)]) == words {
                    return i
                }
            }
            if t == "no" && isDiscourseNo(at: i, in: tokens) { return i }
        }
        return nil
    }

    private static func containsCorrectionMarker(_ tokens: [String]) -> Bool {
        let joined = " " + tokens.joined(separator: " ") + " "
        return correctionMarkers.contains { joined.contains(" \($0) ") }
            || tokens.enumerated().contains { i, t in t == "no" && isDiscourseNo(at: i, in: tokens) }
    }

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000,
        "million": 1_000_000,
        // Ordinals ("second" is left out: "wait a second" is not a number).
        "first": 1, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
    ]

    /// The numbers in a span, as a sorted list. Digit runs count, and so do spoken numbers, with a
    /// run of number words read as one number: "twenty five" is 25, "two hundred fifty" is 250,
    /// "nine thirty" is 9 and 30 (a time), so "9:30", "25" and "250" all agree with their spoken
    /// forms while "eight" vs "nine" does not.
    static func numbers(in text: String) -> [Int] {
        var out: [Int] = []
        let lower = text.lowercased()
        var digits = ""
        for ch in lower {
            if ch.isASCII && ch.isNumber { digits.append(ch) } else {
                if !digits.isEmpty { out.append(Int(digits) ?? -1); digits = "" }
            }
        }
        if !digits.isEmpty { out.append(Int(digits) ?? -1) }
        var current: Int?
        func flush() { if let c = current { out.append(c) }; current = nil }
        for t in tokenize(lower) {
            guard !t.contains(where: \.isNumber), let v = numberWords[t] else { flush(); continue }
            if v == 100 {
                current = (current ?? 1) * 100
            } else if v >= 1000 {
                out.append((current ?? 1) * v)
                current = nil
            } else if let c = current, c >= 20, c < 100, c % 10 == 0, v < 10 {
                current = c + v                         // twenty five
            } else if let c = current, c >= 100, c % 100 == 0, v < 100 {
                current = c + v                         // two hundred fifty
            } else if let c = current, c >= 100, c % 100 >= 20, c % 10 == 0, v < 10 {
                current = c + v                         // two hundred fifty five
            } else {
                flush()
                current = v
            }
        }
        flush()
        return out.sorted()
    }

    /// Words that flip meaning. Contractions are matched on the "n't" ending as well.
    static let negationWords: Set<String> = [
        "not", "no", "never", "nothing", "nobody", "none", "neither", "nor", "cannot",
        "without", "nowhere",
    ]

    /// Phrases that mark a self-correction; a "no" directly next to one is discourse, not negation.
    static let correctionMarkers = ["wait", "sorry", "i mean", "actually", "scratch that"]

    public static func screen(_ edits: [SpanEdit]) -> Screened {
        var kept: [SpanEdit] = []
        var rejected: [SpanEdit] = []
        for edit in edits {
            if rejection(for: edit) == nil {
                kept.append(edit)
            } else {
                rejected.append(edit)
            }
        }
        return Screened(kept: kept, rejected: rejected)
    }

    /// Count negations in `text`, not counting the discourse "no" of a self-correction.
    static func negationCount(_ text: String) -> Int {
        let tokens = tokenize(text)
        var count = 0
        for (i, token) in tokens.enumerated() {
            let isNegation = negationWords.contains(token) || token.hasSuffix("n't")
                || token.hasSuffix("n’t")
            guard isNegation else { continue }
            if token == "no" && isDiscourseNo(at: i, in: tokens) { continue }
            count += 1
        }
        return count
    }

    private static func isDiscourseNo(at i: Int, in tokens: [String]) -> Bool {
        func phrase(from start: Int, words: Int) -> String? {
            guard start >= 0, start + words <= tokens.count else { return nil }
            return tokens[start..<(start + words)].joined(separator: " ")
        }
        for marker in correctionMarkers {
            let n = marker.split(separator: " ").count
            if phrase(from: i + 1, words: n) == marker { return true }   // "no wait"
            if phrase(from: i - n, words: n) == marker { return true }   // "wait no"
        }
        // "no no" repeated is a self-interruption too.
        if i + 1 < tokens.count, tokens[i + 1] == "no" { return true }
        if i > 0, tokens[i - 1] == "no" { return true }
        return false
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits)
                .union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }
}
