import Foundation

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries).
    // Punctuation in lookahead handles whisper appending periods: "Period." "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    // Unambiguous: these phrases are almost never used as regular words in speech.
    // Always safe to replace regardless of context.
    private static var alwaysReplace: [(pattern: String, replacement: String)] {[
        ("\(ws)question marks?\(we)", "?"),
        ("\(ws)exclamation marks?\(we)", "!"),
        ("\(ws)exclamation points?\(we)", "!"),
        ("\(ws)semicolon\(we)", ";"),
        ("\(ws)semi colon\(we)", ";"),
        // Ellipsis removed — whisper generates "..." from pauses causing false positives
        ("\(ws)full stop\(we)", "."),
        ("\(ws)open quote\(we)", "\""),
        ("\(ws)close quote\(we)", "\""),
        ("\(ws)open paren\(we)", "("),
        ("\(ws)close paren\(we)", ")"),
        ("\(ws)new line\(we)", "\n"),
        ("\(ws)newline\(we)", "\n"),
        ("\(ws)new paragraph\(we)", "\n\n"),
    ]}

    // Ambiguous: these words are commonly used as regular words ("comma separating",
    // "period of time", "colon cancer", "dash of salt"). Only replace when whisper
    // signaled a break before the word (preceded by punctuation), indicating the speaker
    // paused — meaning they intended a punctuation command, not a regular word.
    private static var contextReplace: [(pattern: String, replacement: String)] {[
        // Require punctuation immediately before (after optional whitespace):
        // "hello, comma how" → replace ("," before "comma" = whisper saw a break)
        // "comma separating" → skip (no punctuation before = regular word)
        ("(?<=[.,!?;:])\\s*(?:[ck]omma|kana|kanna)\(we)", ","),
        ("(?<=[.,!?;:])\\s*period\(we)", "."),
        ("(?<=[.,!?;:])\\s*colon\(we)", ":"),
        ("(?<=[.,!?;:])\\s*dash\(we)", " —"),
        ("(?<=[.,!?;:])\\s*hyphen\(we)", "-"),
    ]}

    // Ellipsis support removed — whisper generates "..." from pauses, causing false positives.
    // All multi-dot sequences are now stripped unconditionally.

    // Fallback replacements for spoken mode (no whisper auto-punct, so no context to read).
    // These use the same boundaries as alwaysReplace — replace regardless of surrounding punct.
    private static var spokenFallback: [(pattern: String, replacement: String)] {[
        ("\(ws)(?:[ck]omma|kana|kanna)\(we)", ","),
        ("\(ws)period\(we)", "."),
        ("\(ws)colon\(we)", ":"),
        ("\(ws)dash\(we)", " —"),
        ("\(ws)hyphen\(we)", "-"),
    ]}

    /// Process spoken punctuation words into symbols.
    /// - Parameter hybrid: true for hybrid mode (context-aware replacement for ambiguous words),
    ///                     false for spoken mode (always replace everything).
    public static func process(_ text: String, hybrid: Bool = false) -> String {
        var result = text

        // 1. Convert whisper's auto-commas before capitals to periods FIRST,
        // before spoken punctuation replaces words like "comma" with literal commas.
        // This way, user-intentional commas (from saying "comma") won't be overridden.
        result = commaBeforeCapitalToPeriod(result)

        // 2. Replace unambiguous spoken punctuation words (always safe)
        for (pattern, replacement) in alwaysReplace {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2. Replace ambiguous words — strategy depends on mode
        let ambiguous = hybrid ? contextReplace : spokenFallback
        for (pattern, replacement) in ambiguous {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        // 2.5. In hybrid mode, catch ambiguous words the context-aware regex missed.
        // The context regex requires preceding punctuation, but users often say
        // "word comma word" without whisper adding a comma first.
        if hybrid {
            result = convertStandaloneAmbiguous(result)
        }

        // 3. Strip all multi-dot sequences and unicode ellipsis (whisper pause artifacts)
        if let dotsRegex = try? NSRegularExpression(pattern: "\\.{2,}", options: []) {
            result = dotsRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        result = result.replacingOccurrences(of: "\u{2026}", with: "")

        // 4. Collapse space-separated same-type punctuation BEFORE fixSpacing
        if let regex = try? NSRegularExpression(pattern: "([.,!?;:])(?:\\s*\\1)+", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // 5. Fix spacing: remove whitespace before punctuation marks
        result = fixSpacingAroundPunctuation(result)

        // 6. Collapse adjacent different-type punctuation conflicts
        result = collapseAdjacentPunctuation(result)

        // 7. Ensure space after punctuation before next word
        result = ensureSpaceAfterPunctuation(result)

        // 7.5. Collapse whisper's comma spam: runs of 3+ consecutive single-word-commas.
        // Pathological pattern: "I'll, try, to, make, it" — whisper inserts commas at every
        // speech pause. Real grammatical commas like "First, let me explain" have only ONE
        // single-word-comma before a multi-word phrase, so they're safe.
        result = collapseCommaSpam(result)

        // 8. Capitalize first letter after sentence-ending punctuation (. ! ?)
        result = capitalizeAfterSentenceEnd(result)

        return result
    }

    /// Find runs of 3+ consecutive "word, word, " patterns and strip the commas.
    /// Whisper's comma-at-every-pause pattern. A run of 3+ means commas are noise;
    /// 1-2 is normal English ("First, ..." / "apples, oranges").
    private static func collapseCommaSpam(_ text: String) -> String {
        // Word chars including apostrophe + hyphen (so "I'll", "don't", "wee-hours" all count as single words)
        // Match a word, then 2+ repetitions of ", word", optionally one more ", word"
        let pattern = #"\b[\w'-]+(?:,\s+[\w'-]+){2,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }

        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let matched = String(text[range])
            // Strip commas between words (but keep the words)
            let fixed = matched.replacingOccurrences(of: ", ", with: " ")
            mutable.replaceCharacters(in: match.range, with: fixed)
        }
        return mutable as String
    }

    // MARK: - Style Modes

    public enum StyleMode {
        case texting    // Signal, iMessage, WhatsApp, SMS
        case slack      // Slack, Discord, Teams
        case email      // Gmail, Outlook, Mail
        case none       // No style processing (default for unknown apps)
    }

    /// Detect style mode from the frontmost app's bundle ID.
    public static func detectStyleMode(bundleID: String?) -> StyleMode {
        guard let id = bundleID?.lowercased() else { return .none }
        // Texting apps
        if id.contains("signal") || id.contains("imessage") || id.contains("messages")
            || id.contains("whatsapp") || id.contains("telegram") || id.contains("sms") {
            return .texting
        }
        // Slack-style work chat
        if id.contains("slack") || id.contains("discord") || id.contains("teams") {
            return .slack
        }
        // Email
        if id.contains("gmail") || id.contains("mail") || id.contains("outlook")
            || id.contains("superhuman") || id.contains("spark") {
            return .email
        }
        return .none
    }

    /// Apply Michael's writing style to transcribed text.
    /// Based on style profiles derived from 172 messages across platforms.
    /// Only modifies text for messaging apps — email and other apps keep normal punctuation.
    public static func applyStyle(_ text: String, mode: StyleMode) -> String {
        // Only apply style processing for messaging apps
        guard mode == .texting || mode == .slack else { return text }

        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return result }

        // Strip trailing period only — mid-sentence periods stay for multi-sentence dictations.
        // Michael never ends messages with a period (0% across texting platforms).
        if result.hasSuffix(".") && !result.hasSuffix("..") {
            let beforeDot = result.dropLast()
            if !beforeDot.isEmpty {
                let lastWord = String(beforeDot.split(separator: " ").last ?? "")
                if lastWord.count > 2 { // keep after abbreviations like "U.S."
                    result = String(beforeDot)
                }
            }
        }

        // Capitalize first letter (90%+ across all platforms)
        if let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }

    /// Convert comma to period when followed by a capitalized word that signals
    /// In dictation, a comma before a capital letter is almost always a sentence break.
    /// Convert all of them — the false positive rate ("Hello, Michael" → "Hello. Michael")
    /// is far lower than the missed-conversion rate with a conservative whitelist.
    private static func commaBeforeCapitalToPeriod(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",\\s+([A-Z])", options: []) else { return text }
        let mutable = NSMutableString(string: text)
        regex.replaceMatches(in: mutable, range: NSRange(location: 0, length: mutable.length), withTemplate: ". $1")
        return mutable as String
    }

    /// Capitalize the first letter after sentence-ending punctuation.
    /// "hello. would love" → "hello. Would love"
    private static func capitalizeAfterSentenceEnd(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?])\\s+(\\w)", options: []) else { return text }
        let mutable = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Process in reverse so ranges stay valid
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            guard let swiftRange = Range(letterRange, in: text) else { continue }
            let upper = text[swiftRange].uppercased()
            mutable.replaceCharacters(in: letterRange, with: upper)
        }
        return mutable as String
    }

    /// In hybrid mode, convert ambiguous punctuation words when they appear as standalone
    /// words between phrases. "things like comma San Francisco" → "things like, San Francisco".
    /// Only skips conversion when the word is part of a compound like "comma separated".
    private static func convertStandaloneAmbiguous(_ text: String) -> String {
        var result = text
        let ambiguousWords: [(word: String, replacement: String, skipBefore: Set<String>)] = [
            ("comma", ",", ["separated", "delimited", "splice", "operator"]),
            ("komma", ",", []),
            ("kana", ",", []),
            ("kanna", ",", []),
            ("period", ".", ["of", "piece"]),
            ("colon", ":", ["cancer", "surgery", "cleanse", "polyp"]),
            ("dash", " —", ["of", "board", "cam"]),
            ("hyphen", "-", ["ated", "ation"]),
        ]

        for (word, replacement, skipBefore) in ambiguousWords {
            // Match the word as a standalone token (word boundaries on both sides)
            let pattern = "(?i)(?<=\\s|^)\(word)(?=\\s|$|[.,!?;:])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }

            // Process matches in reverse so indices stay valid
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }

                // Check if the next word is in the skip list
                let afterMatch = result[range.upperBound...]
                    .drop(while: { $0.isWhitespace })
                let nextWord = String(afterMatch.prefix(while: { $0.isLetter })).lowercased()
                if skipBefore.contains(nextWord) { continue }

                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\s+([.,?!:;...])", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1"
        )
        return result
    }

    /// Collapse punctuation conflicts from hybrid mode (whisper auto-punct + spoken punct).
    private static func collapseAdjacentPunctuation(_ text: String) -> String {
        var result = text

        // Remove comma/semicolon/colon before a sentence-ending mark: ",!" → "!", ";." → "."
        if let regex = try? NSRegularExpression(pattern: "[,;:]\\s*([.!?...])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove period before ! or ? or ellipsis: ".!" → "!"
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*([!?...])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove trailing period after ! or ?: "!." → "!", "?." → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])\\s*\\.", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after ! or ?: "!," → "!", "?," → "?"
        if let regex = try? NSRegularExpression(pattern: "([!?])\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove comma after period: ".," → "." (period is stronger than comma)
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "."
            )
        }

        return result
    }

    private static func ensureSpaceAfterPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "([.,?!:;])(\\w)", options: []) else { return result }
        result = regex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1 $2"
        )
        return result
    }
}
