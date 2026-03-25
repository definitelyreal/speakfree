import Foundation

public struct TextPostProcessor {
    // Boundaries use whitespace OR punctuation (not \b which treats hyphens as boundaries).
    // Punctuation in lookahead handles whisper appending periods: "Period." "Exclamation mark."
    private static let ws = "(?<=[\\s.,!?;:]|^)"
    private static let we = "(?=[\\s.,!?;:]|$)"

    // Unambiguous: these phrases are almost never used as regular words in speech.
    // Always safe to replace regardless of context.
    private static var alwaysReplace: [(pattern: String, replacement: String)] {[
        ("\(ws)question mark\(we)", "?"),
        ("\(ws)exclamation mark\(we)", "!"),
        ("\(ws)exclamation point\(we)", "!"),
        ("\(ws)semicolon\(we)", ";"),
        ("\(ws)semi colon\(we)", ";"),
        ("\(ws)ellipsis\(we)", "..."),
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
        ("(?<=[.,!?;:])\\s*(?:[ck]omma|kana)\(we)", ","),
        ("(?<=[.,!?;:])\\s*period\(we)", "."),
        ("(?<=[.,!?;:])\\s*colon\(we)", ":"),
        ("(?<=[.,!?;:])\\s*dash\(we)", " —"),
        ("(?<=[.,!?;:])\\s*hyphen\(we)", "-"),
    ]}

    // Unicode placeholder for real ellipsis (from spoken "ellipsis" word)
    private static let ellipsisPlaceholder = "\u{FFFE}"

    // Fallback replacements for spoken mode (no whisper auto-punct, so no context to read).
    // These use the same boundaries as alwaysReplace — replace regardless of surrounding punct.
    private static var spokenFallback: [(pattern: String, replacement: String)] {[
        ("\(ws)(?:[ck]omma|kana)\(we)", ","),
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

        // 1. Replace unambiguous spoken punctuation words (always safe)
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

        // 3. Protect real ellipsis (from spoken "ellipsis" word) before collapsing
        result = result.replacingOccurrences(of: "...", with: ellipsisPlaceholder)

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

        // 7. Restore ellipsis
        result = result.replacingOccurrences(of: ellipsisPlaceholder, with: "...")

        // 8. Normalize 4+ dots to ellipsis
        if let regex = try? NSRegularExpression(pattern: "\\.{4,}", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "..."
            )
        }

        // 9. Ensure space after punctuation before next word
        result = ensureSpaceAfterPunctuation(result)

        return result
    }

    private static func fixSpacingAroundPunctuation(_ text: String) -> String {
        var result = text
        guard let regex = try? NSRegularExpression(pattern: "\\s+([.,?!:;\u{FFFE}])", options: []) else { return result }
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
        if let regex = try? NSRegularExpression(pattern: "[,;:]\\s*([.!?\u{FFFE}])", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1"
            )
        }

        // Remove period before ! or ? or ellipsis: ".!" → "!"
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*([!?\u{FFFE}])", options: []) {
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

        // Remove period before comma: ".," → ","
        if let regex = try? NSRegularExpression(pattern: "\\.\\s*,", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ","
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
